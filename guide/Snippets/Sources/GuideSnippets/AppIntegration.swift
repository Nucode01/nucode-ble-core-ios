import Foundation
import NucodeBleCore
import Observation
import SwiftUI

// region guide:observable-model
/// 화면 하나가 기기 하나를 다루는 모델. client 는 앱이 하나 만들어 넘긴다(화면마다 만들지 않는다)
@MainActor
@Observable
final class DeviceModel {
    private(set) var adapter: AdapterState = .unknown
    private(set) var connection: ConnectionState = .disconnected(reason: .initial)
    private(set) var lastMessage: String = ""
    private(set) var errorText: String?

    private let client: any BLEClient
    private let id: PeripheralID
    private var tasks: [Task<Void, Never>] = []

    init(client: any BLEClient, id: PeripheralID) {
        self.client = client
        self.id = id
    }

    /// 화면이 나타날 때. 스트림은 구독하면 현재 값을 먼저 준다
    func appear() {
        guard tasks.isEmpty, let session = try? client.session(for: id) else { return }
        let adapterStates = client.adapterStates
        let connectionStates = session.connectionStates
        let messages = session.notifications(for: NUS.tx)
        tasks = [
            Task { [weak self] in for await s in adapterStates { self?.adapter = s } },
            Task { [weak self] in for await s in connectionStates { self?.connection = s } },
            Task { [weak self] in
                for await value in messages { self?.lastMessage = String(decoding: value, as: UTF8.self) }
            },
        ]
    }

    /// 화면이 사라질 때. 관찰만 멈춘다. 연결은 남는다
    func disappear() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    func connect() async {
        await run {
            let session = try await self.client.connect(self.id, options: ConnectOptions(autoReconnect: true))
            try await waitUntilReady(session)
            try await session.subscribe(NUS.tx)
        }
    }

    func send(_ text: String) async {
        await run {
            _ = try await self.client.session(for: self.id).write(NUS.rx, value: Data(text.utf8), options: WriteOptions())
        }
    }

    func disconnect() async {
        guard let session = try? client.session(for: id) else { return }
        await session.disconnect()
    }

    var canSend: Bool {
        if case .ready = connection { return true }
        return false
    }

    private func run(_ body: () async throws -> Void) async {
        errorText = nil
        do { try await body() } catch { errorText = userMessage(for: error) }
    }
}

struct DeviceView: View {
    @State var model: DeviceModel
    @State private var draft = ""

    var body: some View {
        Form {
            if let text = adapterMessage(model.adapter) { Text(text).foregroundStyle(.orange) }
            Text("상태: \(String(describing: model.connection))")
            Button("연결") { Task { await model.connect() } }
            TextField("보낼 내용", text: $draft)
            Button("보내기") { Task { await model.send(draft) } }.disabled(!model.canSend)
            Text("받은 값: \(model.lastMessage)")
            if let error = model.errorText { Text(error).foregroundStyle(.red) }
        }
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
    }
}
// endregion

#if canImport(UIKit)
import UIKit

// region guide:restoration
/// 상태 복원을 쓰는 앱의 시작 코드. 시스템이 앱을 백그라운드에서 다시 실행하면 화면 없이 이 함수만 불린다.
/// 그래서 client 생성 · 등록 · start 는 화면(onAppear)이 아니라 여기서 한다
final class AppDelegate: NSObject, UIApplicationDelegate {
    let ble = BLEClientFactory.make(options: BLEOptions(restoreIdentifier: "com.example.app.ble"))

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // register · registerScan · onNotification 은 start() 전에만 부를 수 있다(뒤에 부르면 trap)
        if let saved = savedDevice() {
            ble.register(saved, options: ConnectOptions(autoReconnect: true), subscribe: [NUS.tx])
        }
        // 등록한 characteristic 의 알림은 세션 단계와 상관없이 여기로 온다(복원 직후 Ready 전 알림 포함)
        ble.onNotification(queue: .main) { id, characteristic, value in
            MainActor.assumeIsolated {
                Inbox.shared.append(device: id, value: value) // 받자마자 저장한다. 곧 다시 일시정지될 수 있다
            }
        }
        ble.start() // poweredOn 이 되면 등록한 기기에 connect(options) 와 같은 경로로 연결한다
        return true
    }
}

@MainActor
final class Inbox {
    static let shared = Inbox()
    private(set) var items: [(PeripheralID, Data)] = []
    func append(device: PeripheralID, value: Data) { items.append((device, value)) }
}

/// SwiftUI 앱은 AppDelegate 를 어댑터로 붙인다. 실제 앱에서는 이 타입에 `@main` 을 단다
struct RestorationApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            if let id = savedDevice() {
                DeviceView(model: DeviceModel(client: appDelegate.ble, id: id))
            } else {
                Text("먼저 기기를 찾아 연결해 주세요")
            }
        }
    }
}
// endregion
#endif

// region guide:client-owner
/// 복원을 쓰지 않는 앱: client 는 앱 수명 동안 하나. 앱 진입점에서 만들어 환경으로 내려준다
@MainActor
final class BLEContainer {
    static let shared = BLEContainer()
    let client: any BLEClient

    private init() {
        client = BLEClientFactory.make()
        client.start()
    }
}
// close() 는 앱이 BLE 를 완전히 그만 쓸 때(로그아웃 등)만 부른다. 닫힌 client 는 되살릴 수 없고 새로 만들어야 한다
// endregion
