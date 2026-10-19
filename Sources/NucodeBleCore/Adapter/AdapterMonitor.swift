import Foundation

/// 명령 하나가 어댑터 판정을 기다리는 지점. 결과를 정하는 곳은 `AdapterCore` 이고, 그 결과를 여기에 싣는 곳은 `AdapterMonitor` 뿐이다.
@BLECoreActor
package final class AdapterGate {
    fileprivate let id: AdapterCore.GateID
    fileprivate let waiter = Waiter<Void>()
    fileprivate var timer: Task<Void, Never>?
    private weak var monitor: AdapterMonitor?

    fileprivate init(id: AdapterCore.GateID, monitor: AdapterMonitor) {
        self.id = id
        self.monitor = monitor
    }

    package var isFinished: Bool { waiter.isResolved }

    /// 진입 계층의 마지막 줄에서만 부른다
    package func value() async throws { try await waiter.value() }

    /// 호출자 취소: 대기를 끝낸다
    package func cancel() {
        guard let monitor else {
            finish(.failure(CancellationError()))
            return
        }
        monitor.cancel(id)
    }

    fileprivate func finish(_ outcome: Result<Void, any Error>) {
        timer?.cancel()
        timer = nil
        waiter.resolve(outcome)
    }
}

/// `CBManagerState`·`CBManager.authorization` 을 공개 `AdapterState` 로 옮기고 명령용 어댑터 판정을 한다
/// (contract/states.md §6, docs/v1/ios-design.md §8).
///
/// 판정은 `AdapterCore.step` 이 한다. 여기는 사건을 넘기고 할 일(게시·기한 예약·판정 전달·닫기)을 실행하는 껍데기다.
/// manager(`CentralPort`)는 `attach` 전에 없다. 기다림은 `AdapterGate` 의 Waiter 가 맡는다.
@BLECoreActor
package final class AdapterMonitor {
    /// `unknown` 을 기다리는 상한(밀리초)
    package static let unknownWaitLimit = AdapterCore.unknownWaitLimit

    package let states = StateBroadcaster<AdapterState>(.unknown)
    private let clock: any BLEClock
    private var central: (any CentralPort)?
    /// 어댑터 판정 상태의 유일한 주인. 대입은 `dispatch` 안에서만 한다
    private var core = AdapterCore.State()
    private var gates: [AdapterCore.GateID: AdapterGate] = [:]
    /// 사건 하나를 처리하는 동안(중첩 포함) 깊이와, 그 사이 observer 등이 낸 취소. 게시 도중 온 취소를 판정보다 먼저 적용하는 데 쓴다
    private var dispatchDepth = 0
    private var cancelledInBatch: Set<AdapterCore.GateID> = []
    private var observers: [@BLECoreActor (AdapterState) -> Void] = []

    package init(clock: any BLEClock) {
        self.clock = clock
    }

    package var isClosed: Bool { AdapterCore.isClosed(core) }

    package var current: AdapterState { states.value }

    /// 어댑터 값이 바뀔 때마다 부른다. 세션이 어댑터 이탈과 복귀를 따라가는 통로다
    package func observe(_ observer: @escaping @BLECoreActor (AdapterState) -> Void) {
        observers.append(observer)
    }

    // MARK: 상태

    /// 사용 설명 키가 없어 manager 를 만들지 않는다. 앱이 요청해도 풀리지 않는다(CANDIDATE-25)
    package func publishMissingUsageDescription() {
        dispatch(.usageDescriptionMissing)
    }

    /// manager 가 만들어졌다. 지금 값으로 판정을 시작한다
    package func attach(_ central: any CentralPort) {
        self.central = central
        refresh()
    }

    /// manager 의 state·authorization 을 다시 읽는다
    package func refresh() {
        guard !isClosed, let central else { return }
        dispatch(.platform(Self.radio(central.state), Self.authorization(central.authorization)))
    }

    // MARK: 명령용 판정

    /// 판정 대기를 시작한다. 이미 결정되는 값이면 Waiter 가 바로 끝난 채로 돌아온다.
    package func gate() -> AdapterGate {
        let gate = AdapterGate(id: AdapterCore.nextGateID(core), monitor: self)
        gates[gate.id] = gate
        dispatch(.gateRequested)
        return gate
    }

    fileprivate func cancel(_ id: AdapterCore.GateID) {
        // 판정이 이미 계산돼 전달만 남은 gate 도 취소가 이긴다(0.2.0: observer 가 판정보다 먼저 돌았다)
        if dispatchDepth > 0, gates[id] != nil { cancelledInBatch.insert(id) }
        dispatch(.gateCancelled(id))
    }

    // MARK: 닫기

    /// 대기 중인 판정을 `CLIENT_CLOSED` 로 끝내고 상태 흐름을 닫는다. 마지막 값은 남는다.
    package func close() {
        guard !isClosed else { return }
        central = nil
        observers.removeAll()
        dispatch(.close)
    }

    package static func closedError() -> BLEError { error(.clientClosed, "클라이언트가 닫혔다") }

    private static func error(_ code: FailureCode, _ message: String) -> BLEError {
        BLEError(failure: BLEFailure(code: code, message: message))
    }

    // MARK: 사건과 할 일

    private func dispatch(_ event: AdapterCore.Event) {
        let (next, effects) = AdapterCore.step(core, event)
        core = next
        dispatchDepth += 1
        for effect in effects { perform(effect) }
        dispatchDepth -= 1
        if dispatchDepth == 0 { cancelledInBatch.removeAll() }
    }

    private func perform(_ effect: AdapterCore.Effect) {
        switch effect {
        case .publish(let value):
            states.send(value)
            for observer in observers { observer(value) }
        case .armGateDeadline(let id, let milliseconds):
            gates[id]?.timer = Task { @BLECoreActor [weak self] in
                do { try await self?.clock.sleep(milliseconds: milliseconds) } catch { return }
                guard let self else { return }
                self.dispatch(.gateDeadlineFired(id, authorization: self.central.map { Self.authorization($0.authorization) }))
            }
        case .finishGate(let id, let outcome):
            guard let gate = gates.removeValue(forKey: id) else { return }
            var outcome = outcome
            if cancelledInBatch.contains(id) {
                if case .closed = outcome {} else { outcome = .cancelled }
            }
            switch outcome {
            case .admitted: gate.finish(.success(()))
            case .failed(let failure): gate.finish(.failure(BLEError(failure: failure)))
            case .cancelled: gate.finish(.failure(CancellationError()))
            case .closed: gate.finish(.failure(Self.closedError()))
            }
        case .closeStates:
            states.close()
        }
    }

    // MARK: 포트 값 옮김

    private nonisolated static func radio(_ state: CentralPortState) -> AdapterCore.Radio {
        switch state {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized
        case .poweredOff: return .poweredOff
        case .poweredOn: return .poweredOn
        }
    }

    private nonisolated static func authorization(_ authorization: PortAuthorization) -> AdapterCore.Authorization {
        switch authorization {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .allowedAlways: return .allowedAlways
        }
    }
}
