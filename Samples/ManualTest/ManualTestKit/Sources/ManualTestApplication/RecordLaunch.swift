import Foundation
import ManualTestDomain

/// 표현 계층이 실행 순간에 읽은 값(UIApplication 등). 응용 계층은 UIKit 을 모른다
public struct LaunchContext: Sendable {
    public let launchedInBackground: Bool
    public let appState: String
    public let protectedDataAvailable: Bool
    public let hasBluetoothCentralsKey: Bool
    public init(launchedInBackground: Bool, appState: String, protectedDataAvailable: Bool, hasBluetoothCentralsKey: Bool) {
        self.launchedInBackground = launchedInBackground
        self.appState = appState
        self.protectedDataAvailable = protectedDataAvailable
        self.hasBluetoothCentralsKey = hasBluetoothCentralsKey
    }
}

/// 실행 기록을 남기고 저장된 등록으로 게이트웨이를 시작한다. 시작 직후와 잠시 뒤 snapshot 을 남겨 복원된 세션을 보인다
@MainActor
public struct RecordLaunch {
    let gateway: any BleGateway
    let state: ConsoleState
    let registrationStore: any RegistrationStore
    let settleDelay: Duration

    public init(gateway: any BleGateway, state: ConsoleState, registrationStore: any RegistrationStore, settleDelay: Duration = .seconds(2)) {
        self.gateway = gateway
        self.state = state
        self.registrationStore = registrationStore
        self.settleDelay = settleDelay
    }

    /// didFinishLaunching 에서 동기로 부른다. 돌려준 Task 는 snapshot 기록이다
    @discardableResult
    public func callAsFunction(_ context: LaunchContext) -> Task<Void, Never> {
        var registration: DeviceRegistration?
        do {
            registration = try registrationStore.load()
        } catch {
            state.record(.commandFailed(.saveRegistration, code: "STORE", message: "등록 읽기 실패: \(error)"))
        }
        if let registration { state.mutateSession { $0.adopt(registration) } }
        state.set(registration: registration)
        state.set(activeRegistration: registration)
        state.record(.launched(LaunchRecord(
            reason: .classify(launchedInBackground: context.launchedInBackground),
            appState: context.appState,
            protectedDataAvailable: context.protectedDataAvailable,
            hasBluetoothCentralsKey: context.hasBluetoothCentralsKey,
            registration: registration
        )))
        gateway.start(registration: registration)
        return Task { [gateway, state, settleDelay] in
            state.record(.snapshotTaken(label: "start 직후", await gateway.snapshot()))
            try? await Task.sleep(for: settleDelay)
            state.record(.snapshotTaken(label: "start+\(settleDelay.components.seconds)s", await gateway.snapshot()))
        }
    }
}
