import Foundation

/// 명령 하나가 어댑터 판정을 기다리는 지점. 결과를 정하는 곳은 `AdapterMonitor` 뿐이다.
@BLECoreActor
package final class AdapterGate {
    fileprivate let waiter = Waiter<Void>()
    fileprivate var deadlineReached = false
    fileprivate var timer: Task<Void, Never>?

    fileprivate init() {}

    package var isFinished: Bool { waiter.isResolved }

    /// 진입 계층의 마지막 줄에서만 부른다
    package func value() async throws { try await waiter.value() }

    /// 호출자 취소: 대기를 끝낸다
    package func cancel() { finish(.failure(CancellationError())) }

    fileprivate func finish(_ outcome: Result<Void, any Error>) {
        timer?.cancel()
        timer = nil
        waiter.resolve(outcome)
    }
}

/// `CBManagerState`·`CBManager.authorization` 을 공개 `AdapterState` 로 옮기고 명령용 어댑터 판정을 한다
/// (contract/states.md §6, docs/v1/ios-design.md §8).
///
/// manager(`CentralPort`)는 `attach` 전에 없다. 판정 콜백은 모두 동기이고, 기다림은 `AdapterGate` 의 Waiter 가 맡는다.
@BLECoreActor
package final class AdapterMonitor {
    /// `unknown` 을 기다리는 상한(밀리초)
    package static let unknownWaitLimit = 2000

    package let states = StateBroadcaster<AdapterState>(.unknown)
    private let clock: any BLEClock
    private var central: (any CentralPort)?
    private var pending: [AdapterGate] = []
    private(set) package var isClosed = false
    private var observers: [@BLECoreActor (AdapterState) -> Void] = []

    package init(clock: any BLEClock) {
        self.clock = clock
    }

    package var current: AdapterState { states.value }

    /// 어댑터 값이 바뀔 때마다 부른다. 세션이 어댑터 이탈과 복귀를 따라가는 통로다
    package func observe(_ observer: @escaping @BLECoreActor (AdapterState) -> Void) {
        observers.append(observer)
    }

    // MARK: 상태

    /// 사용 설명 키가 없어 manager 를 만들지 않는다. 앱이 요청해도 풀리지 않는다(CANDIDATE-25)
    package func publishMissingUsageDescription() {
        publish(.unauthorized(canRequest: false))
    }

    /// manager 가 만들어졌다. 지금 값으로 판정을 시작한다
    package func attach(_ central: any CentralPort) {
        self.central = central
        refresh()
    }

    /// manager 의 state·authorization 을 다시 읽는다
    package func refresh() {
        guard !isClosed, let central else { return }
        publish(Self.map(state: central.state, authorization: central.authorization))
    }

    package nonisolated static func map(state: CentralPortState, authorization: PortAuthorization) -> AdapterState {
        switch authorization {
        case .denied, .restricted:
            return .unauthorized(canRequest: false)
        case .notDetermined, .allowedAlways:
            break
        }
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized(canRequest: authorization == .notDetermined)
        case .poweredOff: return .poweredOff
        case .poweredOn: return .ready
        }
    }

    private func publish(_ new: AdapterState) {
        if new != states.value {
            states.send(new)
            for observer in observers { observer(new) }
        }
        evaluatePending()
    }

    // MARK: 명령용 판정

    /// `start()` 로 manager 가 만들어졌고 권한 팝업의 답을 기다리는 중이면 `unknown` 대기에 상한이 없다
    private var isAwaitingPermission: Bool {
        guard let central else { return false }
        return central.authorization == .notDetermined
    }

    /// 판정 대기를 시작한다. 이미 결정되는 값이면 Waiter 가 바로 끝난 채로 돌아온다.
    package func gate() -> AdapterGate {
        pending.removeAll(where: \.isFinished)
        let gate = AdapterGate()
        guard !isClosed else {
            gate.finish(.failure(Self.closedError()))
            return gate
        }
        evaluate(gate)
        guard !gate.isFinished else { return gate }
        pending.append(gate)
        gate.timer = Task { @BLECoreActor [weak self, weak gate] in
            do { try await self?.clock.sleep(milliseconds: Self.unknownWaitLimit) } catch { return }
            guard let self, let gate else { return }
            gate.deadlineReached = true
            self.evaluate(gate)
            self.pending.removeAll(where: \.isFinished)
        }
        return gate
    }

    private func evaluatePending() {
        for gate in pending { evaluate(gate) }
        pending.removeAll(where: \.isFinished)
    }

    private func evaluate(_ gate: AdapterGate) {
        guard !gate.isFinished else { return }
        switch states.value {
        case .ready:
            gate.finish(.success(()))
        case .poweredOff:
            gate.finish(.failure(Self.error(.adapterUnavailable, "Bluetooth 가 꺼져 있다")))
        case .resetting:
            gate.finish(.failure(Self.error(.adapterUnavailable, "Bluetooth 가 재설정 중이다")))
        case .unauthorized(let canRequest):
            gate.finish(.failure(BLEError(failure: BLEFailure(
                code: .permissionDenied,
                message: "Bluetooth 권한이 없다",
                retryability: canRequest ? .afterEnvironmentChange : .never
            ))))
        case .unsupported:
            gate.finish(.failure(Self.error(.bleUnsupported, "이 기기는 BLE central 을 지원하지 않는다")))
        case .unknown:
            if gate.deadlineReached && !isAwaitingPermission {
                gate.finish(.failure(Self.error(.adapterUnavailable, "어댑터 상태를 \(Self.unknownWaitLimit)ms 안에 알 수 없었다")))
            }
        }
    }

    // MARK: 닫기

    /// 대기 중인 판정을 `CLIENT_CLOSED` 로 끝내고 상태 흐름을 닫는다. 마지막 값은 남는다.
    package func close() {
        guard !isClosed else { return }
        isClosed = true
        central = nil
        observers.removeAll()
        for gate in pending { gate.finish(.failure(Self.closedError())) }
        pending.removeAll()
        states.close()
    }

    package static func closedError() -> BLEError { error(.clientClosed, "클라이언트가 닫혔다") }

    private static func error(_ code: FailureCode, _ message: String) -> BLEError {
        BLEError(failure: BLEFailure(code: code, message: message))
    }
}
