# 레시피: 앱 구조에 넣기

## client 는 누가 갖나

<!-- snippet: client-owner -->
```swift
/// 복원을 쓰지 않는 앱: client 는 앱 수명 동안 하나. 앱 진입점에서 만들어 환경으로 내려준다
@MainActor
final class BLEContainer {
    static let shared = BLEContainer()
    let client: BLEClient

    private init() {
        client = BLEClient()
        client.start()
    }
}
// close() 는 앱이 BLE 를 완전히 그만 쓸 때(로그아웃 등)만 부른다. 닫힌 client 는 되살릴 수 없고 새로 만들어야 한다
```

- **앱당 하나, 앱 수명 동안.** 화면이나 ViewModel 이 만들고 버리면 그때마다 연결 · 구독이 끊깁니다.
- 테스트나 미리보기에서 client 를 바꾸고 싶으면 client 를 쓰는 쪽을 앱의 프로토콜 뒤에 두세요. 라이브러리는 가짜 client 를 공개하지 않습니다.
  예: 이 저장소의 `Samples/ManualTest` 는 도메인 쪽 `BleGateway` 프로토콜과 그 구현 `NucodeBleGateway` 로 나눴습니다.

## SwiftUI 모델

<!-- snippet: observable-model -->
```swift
/// 화면 하나가 기기 하나를 다루는 모델. client 는 앱이 하나 만들어 넘긴다(화면마다 만들지 않는다)
@MainActor
@Observable
final class DeviceModel {
    private(set) var adapter: AdapterState = .unknown
    private(set) var connection: ConnectionState = .disconnected(reason: .initial)
    private(set) var lastMessage: String = ""
    private(set) var errorText: String?

    private let client: BLEClient
    private let id: PeripheralID
    private var tasks: [Task<Void, Never>] = []

    init(client: BLEClient, id: PeripheralID) {
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
```

- 스트림은 라이브러리 큐에서 값을 내므로 `@MainActor` 모델의 Task 로 받아 화면 상태에 옮깁니다. `Task { … }` 는 `@MainActor` 문맥을 물려받습니다.
- 화면이 사라질 때 **관찰만** 멈춥니다. 연결을 끊을지는 앱이 정합니다.
- 스트림을 Task 밖에서 먼저 얻은 뒤(`let adapterStates = client.adapterStates`) Task 안에서 돌면, 구독이 `appear()` 안에서 동기로 걸립니다.

## 상태 복원

**언제 쓰나.** 앱이 백그라운드에 있는 동안 시스템이 메모리 때문에 앱을 종료해도, 기기 알림이 오면 앱을 다시 깨워 연결 · 구독을 이어가야 할 때.

| 상황 | 복원 없이 | 복원으로 |
|---|---|---|
| 포그라운드 · 백그라운드 일시정지 | 연결 유지 · 알림 수신(`bluetooth-central`) | 같음 |
| **시스템이 앱을 종료** | 연결 · 대기 연결 · 구독이 사라짐 | iOS 가 들고 있다가 기기 이벤트가 오면 앱을 백그라운드로 다시 실행하고 넘겨줌 |
| 폰 재부팅 | 사라짐 | 등록한 기기로 다시 연결(실기기에서 확인) |
| 사용자가 앱 전환기에서 강제 종료 | 사라짐 | 사라짐(iOS 정책) |

<!-- snippet: restoration -->
```swift
/// 상태 복원을 쓰는 앱의 시작 코드. 시스템이 앱을 백그라운드에서 다시 실행하면 화면 없이 이 함수만 불린다.
/// 그래서 client 생성 · 등록 · start 는 화면(onAppear)이 아니라 여기서 한다
final class AppDelegate: NSObject, UIApplicationDelegate {
    let ble = BLEClient(options: BLEOptions(restoreIdentifier: "com.example.app.ble"))

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
```

규칙:

1. **`BLEOptions(restoreIdentifier:)`** 에 앱마다 고정된 문자열을 줍니다. 한 프로세스에서 같은 값으로 client 를 두 번 만들면 trap 합니다.
   `close()` 해도 그 값은 풀리지 않으므로, 복원을 쓰는 client 는 닫지 말고 앱 수명 동안 둡니다.
2. **`register` · `registerScan` · `onNotification` 은 `start()` 전에** 부릅니다. 뒤에 부르면 trap 합니다.
3. **`didFinishLaunchingWithOptions` 에서** 합니다. 재실행은 화면 없이 일어나서 `onAppear` · `App.init` 의 코드는 늦거나 불리지 않을 수 있습니다.
   SwiftUI 앱은 `@UIApplicationDelegateAdaptor` 로 AppDelegate 를 붙입니다.
4. **알림은 `onNotification` 핸들러에서 처리하고 바로 저장**합니다. 백그라운드로 깨어난 앱은 처리할 시간이 짧습니다(약 10초).
   세션이 `ready` 가 되기 전에 온 알림도 이 핸들러로 옵니다.
5. `register` 한 기기는 블루투스가 `ready` 가 되면 `connect(options)` 와 같은 경로로 연결합니다. 앱이 따로 `connect()` 를 부를 필요가 없고,
   불러도 같은 옵션이면 합류합니다.
6. 복원된 연결 중 **등록하지 않은** 기기는 끊습니다(세션 없는 연결이 기기를 붙잡지 않게). 계속 쓸 기기는 반드시 `register` 하세요.
7. `registerScan` 을 하지 않으면 복원된 스캔은 멈춥니다. 백그라운드 스캔은 `serviceUUIDs` 필터가 있어야 동작합니다.

`onNotification` 과 `session.notifications(for:)` 를 **둘 다** 쓰면, 등록한 characteristic 의 알림은 두 곳에 모두 옵니다. 한 곳에서만 세세요.

### 복원 동작 확인하기

개발 중에 "시스템이 앱을 종료"를 재현하는 방법입니다. 사용자 강제 종료(앱 전환기에서 쓸어 올리기)로는 확인할 수 없습니다.

1. 기기를 연결 · 구독한 상태로 앱을 백그라운드에 둡니다.
2. Xcode 디버거가 붙어 있으면 떼고(디버거 Stop 은 사용자 강제 종료로 취급될 수 있습니다), Mac 에서 앱 프로세스에 SIGKILL 을 보냅니다.
   ```sh
   xcrun devicectl device info processes --device <기기 UDID> | grep <앱 이름>   # pid 확인
   xcrun devicectl device process signal --device <기기 UDID> --signal SIGKILL --pid <pid>
   ```
3. 기기가 알림을 보내게 합니다. 수 초 안에 iOS 가 앱을 백그라운드로 다시 실행하고, 핸들러에 알림이 와야 합니다.

## `close()`

- 스캔을 멈추고, 모든 세션을 끊고, 모든 스트림을 끝냅니다. 대기 중 명령은 `CLIENT_CLOSED` 로 끝납니다. 멱등입니다.
- 닫힌 client 는 되살릴 수 없습니다. 다시 쓰려면 새로 만들어야 하는데, `restoreIdentifier` 를 쓰는 client 는 같은 값으로 다시 만들 수 없습니다(trap).
- 그래서 대부분의 앱은 `close()` 를 부르지 않습니다. 로그아웃처럼 BLE 를 완전히 그만 쓸 때, 복원을 쓰지 않는 client 에만 부르세요.
  기기 연결만 끊으려면 `session.disconnect()` 를 씁니다.
