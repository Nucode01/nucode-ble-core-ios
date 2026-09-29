import Foundation

/// 연결 상태 기계(contract/states.md §1~§5). `(상태, 사건) → (새 상태, 할 일 목록)` 순수 함수다.
/// 입출력·시간·스레드·플랫폼 타입을 쓰지 않는다. 시간은 사건의 `now`, 기한은 `armTimer`/`timerFired` 로 오간다.
package enum ConnectionCore {
    /// 시작 전 시도(어댑터 판정 → 기기 확보 → OS 연결 요청)
    package struct PendingAttempt {
        package let generation: UInt64
        package let options: ConnectOptions
        /// link 기한의 절대 시각(사건의 `now` 와 같은 기준). autoReconnect 면 없다
        package let linkDeadlineAt: Int?
    }

    package struct State {
        package var phase: ConnectionState = .disconnected(reason: .initial)
        package var generation: UInt64 = 0
        /// OS 가 연결 요청을 받은 시도의 세대. 링크가 끝나면 nil
        package var live: UInt64?
        package var attempt: PendingAttempt?
        /// 마지막으로 OS 가 받아들인 연결 의도
        package var intent: ConnectOptions?
        /// 이 연결이 Ready 에 닿은 적이 있다
        package var hasBeenReady = false
        /// autoReconnect 세션이 어댑터 이탈로 끝났다. 어댑터가 돌아오면 한 번 다시 연결한다
        package var resumeOnAdapterReady = false
        package var closed = false
        /// 열린 채 닫힌 세션의 마지막 단계. 스냅숏에만 쓰인다
        package var closedPhase: ConnectionState?

        package init() {}
    }

    package enum TimerKind {
        case link
        case configuration
        case cleanup
    }

    package enum Event {
        case connect(options: ConnectOptions, now: Int)
        /// 시작 전 시도 실패(어댑터 판정 실패, 기기 확보 실패, 호출자 취소)
        case attemptFailed(generation: UInt64)
        case attemptAccepted(generation: UInt64, now: Int)
        /// `sameDevice`: 콜백의 기기가 Runtime 이 들고 있는 기기다
        case linkConnected(sameDevice: Bool)
        case linkDisconnected(sameDevice: Bool, failure: BLEFailure)
        case linkFailedToConnect(sameDevice: Bool, failure: BLEFailure)
        case timerFired(kind: TimerKind, generation: UInt64)
        case adapterChanged(AdapterState, now: Int)
        /// `failure` 가 nil 이면 탐색 성공
        case discoveryFinished(generation: UInt64, failure: BLEFailure?)
        case configurationFinished(generation: UInt64)
        /// `hasLinkTarget`: 기기와 central 이 있다. `linked`: 기기가 실제로 붙어 있다
        case disconnect(hasLinkTarget: Bool, linked: Bool)
        case operationsPoisoned(failure: BLEFailure)
        case registeredStartFailed(failure: BLEFailure)
        case close
    }

    package enum Effect {
        case publish(ConnectionState)
        case beginAttempt(generation: UInt64, options: ConnectOptions, linkDeadlineAt: Int?)
        case joinAttempt
        case rejectConnect(BLEFailure)
        /// 대상은 세대로 가린다. Runtime 은 자기가 든 시도의 세대와 같을 때만 푼다
        case abortAttempt(generation: UInt64)
        case resolveAttempt(generation: UInt64)
        case connectPeripheral
        case cancelPeripheralConnection
        case armTimer(kind: TimerKind, generation: UInt64, milliseconds: Int)
        case cancelTimer(kind: TimerKind)
        case cancelTimers
        case startDiscovery(generation: UInt64)
        case cancelDiscovery
        case commitServices
        case startConfiguration(generation: UInt64)
        case dropLinkBoundState(message: String)
        case clearSubscriptionIntent
        case openDisconnectWaiter
        case awaitDisconnect
        case resolveDisconnectWaiter
        case diagnostic(code: FailureCode, message: String)
        case closeGattState
        case releasePeripheralOnClose
        case closeFlows
    }

    // MARK: 전이

    package static func step(_ state: State, _ event: Event) -> (State, [Effect]) {
        var next = state
        var effects: [Effect] = []
        if case .close = event {
            close(&next, &effects)
            return (next, effects)
        }
        if state.closed { return (state, []) }
        switch event {
        case .connect(let options, let now):
            connect(&next, &effects, options, now)
        case .attemptFailed(let generation):
            guard next.attempt?.generation == generation else { break }
            next.attempt = nil
            effects.append(.abortAttempt(generation: generation))
        case .attemptAccepted(let generation, let now):
            accept(&next, &effects, generation, now)
        case .linkConnected(let sameDevice):
            guard sameDevice, let live = next.live else { break }
            switch next.phase {
            case .connecting, .recovering: break
            default: return (state, [])
            }
            next.phase = .discoveringServices
            effects += [.cancelTimer(kind: .link), .publish(next.phase), .startDiscovery(generation: live)]
        case .linkDisconnected(let sameDevice, let failure):
            guard sameDevice, next.live != nil else { break }
            linkDisconnected(&next, &effects, failure)
        case .linkFailedToConnect(let sameDevice, let failure):
            guard sameDevice, next.live != nil else { break }
            switch next.phase {
            case .connecting, .recovering: endLink(&next, &effects, .failed(failure))
            default: break
            }
        case .timerFired(let kind, let generation):
            timerFired(&next, &effects, kind, generation)
        case .adapterChanged(let adapter, let now):
            adapterChanged(&next, &effects, adapter, now)
        case .discoveryFinished(let generation, let failure):
            guard next.live == generation, case .discoveringServices = next.phase else { break }
            if let failure {
                abandonLink(&next, &effects, .failed(failure))
                break
            }
            next.phase = .configuring
            effects += [
                .commitServices,
                .publish(next.phase),
                .armTimer(kind: .configuration, generation: generation, milliseconds: Deadlines.configuration),
                .startConfiguration(generation: generation),
            ]
        case .configurationFinished(let generation):
            guard next.live == generation, case .configuring = next.phase else { break }
            next.hasBeenReady = true
            next.phase = .ready
            effects += [.cancelTimer(kind: .configuration), .publish(next.phase)]
        case .disconnect(let hasLinkTarget, let linked):
            disconnect(&next, &effects, hasLinkTarget, linked)
        case .operationsPoisoned(let failure):
            switch next.phase {
            case .configuring, .ready: abandonLink(&next, &effects, .failed(failure))
            default: break
            }
        case .registeredStartFailed(let failure):
            guard case .disconnected = next.phase else { break }
            next.phase = .disconnected(reason: .failed(failure))
            effects += [
                .publish(next.phase),
                .diagnostic(code: failure.code, message: "등록 기기 시작 연결이 실패했다: \(failure.message)"),
            ]
        case .close:
            break
        }
        return (next, effects)
    }

    // MARK: connect 진입 (§4)

    private static func optionsConflict() -> BLEFailure {
        BLEFailure(code: .connectionOptionsConflict, message: "다른 옵션으로 이미 연결 중이다")
    }

    private static func connect(_ s: inout State, _ fx: inout [Effect], _ options: ConnectOptions, _ now: Int) {
        if let attempt = s.attempt {
            fx.append(attempt.options == options ? .joinAttempt : .rejectConnect(optionsConflict()))
            return
        }
        switch s.phase {
        case .disconnecting:
            fx.append(.rejectConnect(BLEFailure(code: .connectDuringDisconnect, message: "해제 정리 중이라 연결할 수 없다")))
        case .connecting, .discoveringServices, .configuring, .ready, .recovering:
            if s.intent != options { fx.append(.rejectConnect(optionsConflict())) }
        case .disconnected:
            startAttempt(&s, &fx, options, now)
        }
    }

    private static func startAttempt(_ s: inout State, _ fx: inout [Effect], _ options: ConnectOptions, _ now: Int) {
        s.generation += 1
        s.resumeOnAdapterReady = false
        let deadline = options.autoReconnect ? nil : now + Deadlines.link
        s.attempt = PendingAttempt(generation: s.generation, options: options, linkDeadlineAt: deadline)
        fx.append(.beginAttempt(generation: s.generation, options: options, linkDeadlineAt: deadline))
    }

    private static func accept(_ s: inout State, _ fx: inout [Effect], _ generation: UInt64, _ now: Int) {
        guard let attempt = s.attempt, attempt.generation == generation else { return }
        s.attempt = nil
        s.intent = attempt.options
        s.live = generation
        s.hasBeenReady = false
        s.phase = .connecting
        fx += [.publish(.connecting), .connectPeripheral]
        if let deadlineAt = attempt.linkDeadlineAt {
            fx.append(.armTimer(kind: .link, generation: generation, milliseconds: max(0, deadlineAt - now)))
        }
        fx.append(.resolveAttempt(generation: generation))
    }

    // MARK: 링크 (§2·§3)

    private static func linkDisconnected(_ s: inout State, _ fx: inout [Effect], _ failure: BLEFailure) {
        switch s.phase {
        case .disconnecting:
            endLink(&s, &fx, .requested)
        case .connecting:
            endLink(&s, &fx, .failed(failure))
        case .discoveringServices, .configuring, .ready:
            if s.hasBeenReady, s.intent?.autoReconnect == true {
                s.phase = .recovering(lastFailure: failure)
                fx += [.cancelTimers, .cancelDiscovery, .publish(s.phase), .dropLinkBoundState(message: "링크가 끊겨 작업이 무효가 됐다"), .connectPeripheral]
            } else {
                endLink(&s, &fx, .failed(failure))
            }
        case .recovering, .disconnected:
            break
        }
    }

    /// 진행 중이던 것을 모두 거두고 상태를 게시한다
    private static func endLink(_ s: inout State, _ fx: inout [Effect], _ reason: DisconnectReason) {
        s.live = nil
        s.phase = .disconnected(reason: reason)
        fx += [.cancelTimers, .cancelDiscovery, .dropLinkBoundState(message: invalidationMessage(reason)), .publish(s.phase), .resolveDisconnectWaiter]
    }

    /// 링크를 우리가 끊는다: 실패로 게시하고 OS 에 연결 취소를 요청한다
    private static func abandonLink(_ s: inout State, _ fx: inout [Effect], _ reason: DisconnectReason) {
        endLink(&s, &fx, reason)
        fx.append(.cancelPeripheralConnection)
    }

    package static func invalidationMessage(_ reason: DisconnectReason) -> String {
        switch reason {
        case .initial, .requested: "사용자가 연결을 끊었다"
        case .clientClosed: "클라이언트가 닫혔다"
        case .failed(let failure): "연결이 끝나 작업이 무효가 됐다: \(failure.message)"
        }
    }

    // MARK: 기한 (§2)

    private static func timerFired(_ s: inout State, _ fx: inout [Effect], _ kind: TimerKind, _ generation: UInt64) {
        guard s.live == generation else { return }
        switch (kind, s.phase) {
        case (.link, .connecting):
            abandonLink(&s, &fx, .failed(BLEFailure(code: .linkTimeout, message: "\(Deadlines.link)ms 안에 링크가 붙지 않았다")))
        case (.configuration, .configuring):
            abandonLink(&s, &fx, .failed(BLEFailure(code: .configurationTimeout, message: "\(Deadlines.configuration)ms 안에 설정이 끝나지 않았다")))
        case (.cleanup, .disconnecting):
            fx.append(.diagnostic(
                code: .disconnectCleanupTimeout,
                message: "\(Deadlines.disconnectCleanup)ms 안에 해제 콜백이 오지 않아 강제로 끝낸다"
            ))
            endLink(&s, &fx, .requested)
        default:
            break
        }
    }

    // MARK: 어댑터 이탈과 복귀 (§2)

    private static func adapterChanged(_ s: inout State, _ fx: inout [Effect], _ adapter: AdapterState, _ now: Int) {
        if adapter == .ready {
            guard s.resumeOnAdapterReady, s.attempt == nil, case .disconnected = s.phase, let options = s.intent else { return }
            s.resumeOnAdapterReady = false
            startAttempt(&s, &fx, options, now)
            return
        }
        switch s.phase {
        case .connecting, .discoveringServices, .configuring, .ready, .recovering: break
        case .disconnecting, .disconnected: return
        }
        let failure: BLEFailure
        if case .unauthorized(let canRequest) = adapter {
            failure = BLEFailure(
                code: .permissionDenied,
                message: "Bluetooth 권한을 잃었다",
                retryability: canRequest ? .afterEnvironmentChange : .never
            )
        } else {
            failure = BLEFailure(code: .adapterUnavailable, message: "어댑터가 Ready 를 벗어났다")
        }
        s.resumeOnAdapterReady = s.intent?.autoReconnect == true
        abandonLink(&s, &fx, .failed(failure))
    }

    // MARK: disconnect (§2·§10)

    private static func disconnect(_ s: inout State, _ fx: inout [Effect], _ hasLinkTarget: Bool, _ linked: Bool) {
        switch s.phase {
        case .disconnected:
            s.resumeOnAdapterReady = false
            fx.append(.clearSubscriptionIntent)
            if let attempt = s.attempt {
                s.attempt = nil
                fx.append(.abortAttempt(generation: attempt.generation))
            }
        case .disconnecting:
            fx.append(.awaitDisconnect)
        case .connecting, .discoveringServices, .configuring, .ready, .recovering:
            s.intent = nil
            s.phase = .disconnecting
            fx += [
                .openDisconnectWaiter, .clearSubscriptionIntent, .cancelTimers, .cancelDiscovery,
                .publish(.disconnecting), .dropLinkBoundState(message: "사용자가 연결을 끊었다"),
            ]
            if let generation = s.live, hasLinkTarget {
                // 붙지 않은 대기 connect 를 취소하면 OS 는 콜백을 주지 않는다
                fx.append(.cancelPeripheralConnection)
                if linked {
                    fx.append(.armTimer(kind: .cleanup, generation: generation, milliseconds: Deadlines.disconnectCleanup))
                } else {
                    endLink(&s, &fx, .requested)
                }
            } else {
                endLink(&s, &fx, .requested)
            }
            fx.append(.awaitDisconnect)
        }
    }

    // MARK: 닫힘 (§9)

    private static func close(_ s: inout State, _ fx: inout [Effect]) {
        guard !s.closed else { return }
        s.closed = true
        if let attempt = s.attempt {
            s.attempt = nil
            fx.append(.abortAttempt(generation: attempt.generation))
        }
        s.live = nil
        s.resumeOnAdapterReady = false
        if case .disconnected = s.phase {} else {
            s.closedPhase = .disconnected(reason: .clientClosed)
        }
        fx += [.cancelTimers, .cancelDiscovery, .closeGattState, .releasePeripheralOnClose, .resolveDisconnectWaiter, .closeFlows]
    }

    // MARK: 질의

    /// 스냅숏이 보는 단계. 열린 채 닫힌 세션은 `Disconnected(ClientClosed)`
    package static func snapshotPhase(_ s: State) -> ConnectionState {
        s.closedPhase ?? s.phase
    }

    /// GATT 명령 진입 검사(§5·§9). 통과하면 nil
    package static func gattAdmission(_ s: State) -> FailureCode? {
        if s.closed { return .clientClosed }
        switch s.phase {
        case .ready: return nil
        case .connecting, .discoveringServices, .configuring: return .notReady
        case .disconnected, .disconnecting, .recovering: return .notConnected
        }
    }

    /// GATT 콜백은 같은 세대의 Configuring·Ready 에서만 받는다
    package static func acceptsGattCallback(_ s: State, sameDevice: Bool, generation: UInt64) -> Bool {
        guard sameDevice, s.live == generation else { return false }
        switch s.phase {
        case .configuring, .ready: return true
        default: return false
        }
    }

    /// 서비스 탐색 콜백은 같은 세대의 DiscoveringServices 에서만 받는다
    package static func acceptsDiscoveryCallback(_ s: State, sameDevice: Bool, generation: UInt64) -> Bool {
        guard sameDevice, s.live == generation, case .discoveringServices = s.phase else { return false }
        return true
    }

    package static func isConfiguring(_ s: State, generation: UInt64) -> Bool {
        guard s.live == generation, case .configuring = s.phase else { return false }
        return true
    }

    package static func isReady(_ s: State) -> Bool {
        if case .ready = s.phase { return true }
        return false
    }
}
