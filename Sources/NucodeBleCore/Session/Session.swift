import Foundation

/// 기기 하나의 세션 상태. `Disconnected(Initial)` 로 태어난다(docs/v1/ios-design.md §6).
/// 연결 진입, 링크 시작(서비스 탐색), 해제, read·구독 명령까지다. write 는 뒤 task 가 채운다.
@BLECoreActor
package final class Session {
    package let peripheralID: PeripheralID
    package let state = StateBroadcaster<ConnectionState>(.disconnected(reason: .initial))
    private(set) package var services: [GATTService] = []
    private(set) package var subscriptions: Set<CharacteristicRef> = []
    /// 서비스 목록 흐름. 끊겨도 비우지 않는다
    package let servicesFlow = StateBroadcaster<[GATTService]>([])
    /// 이 연결에서 CCCD 가 확인된 ref 집합. `subscriptions`(의도)와 다르다
    package let activeSubscriptionsFlow = StateBroadcaster<Set<CharacteristicRef>>([])
    /// Configuring 단계의 일을 바꿔 끼우는 시험용 자리. 끝나면 인자로 받은 완료 함수를 부른다. 없으면 구독 의도를 복원한다
    /// 등록된 알림 통로. 세션 단계와 무관하게 온 값을 앱에 넘긴다. 등록 기기의 세션에만 있다
    package var notificationTap: (@BLECoreActor (_ characteristic: CharacteristicRef, _ value: Data) -> Void)?
    package var configurationStep: (@BLECoreActor (_ done: @escaping @BLECoreActor () -> Void) -> Void)?

    /// 링크: 확보한 기기 객체(강한 참조)와 세대. 오래된 콜백을 걸러 내는 기준이다
    /// 링크가 아직 없어도 복원 번역기가 받아둔 기기를 넣는다(`RestoreTranslator`). 연결 경로가 이 객체를 그대로 쓴다
    package var peripheral: (any PeripheralPort)?
    private(set) package var generation: UInt64 = 0
    /// 마지막으로 OS 가 받아들인 연결 의도
    private(set) package var intent: ConnectOptions?

    /// OS 가 연결 요청을 받은 시도의 세대. 링크가 끝나면 nil. central 콜백은 이것과 `peripheral` 이 맞아야 처리한다
    private var liveGeneration: UInt64?
    private var attempt: ConnectAttempt?
    private var linkDeadline: Task<Void, Never>?
    private var setup: LinkSetup?
    private var delegateRelay: SessionPeripheralDelegate?
    private var configurationDeadline: Task<Void, Never>?
    private var cleanupDeadline: Task<Void, Never>?
    private var disconnectWaiter: Waiter<Void>?
    /// 이 연결이 Ready 에 닿은 적이 있다. Recovering 은 그 뒤의 링크 유실에만 쓴다
    private var hasBeenReady = false
    /// autoReconnect 세션이 어댑터 이탈로 끝났다. 어댑터가 Ready 로 돌아오면 한 번 다시 연결한다
    private var resumeOnAdapterReady = false
    private let context: SessionContext

    // GATT 명령. 참조는 공개(instanceIndex) 쪽과 플랫폼(포트) 쪽을 오간다
    private(set) package var isClosed = false
    /// 열린 채 닫힌 세션의 마지막 상태. 스냅숏에만 쓰인다
    private var closedState: ConnectionState?
    private let operations: OperationQueue
    private var portRefs: [CharacteristicRef: CharacteristicRef] = [:]
    private var publicRefs: [CharacteristicRef: CharacteristicRef] = [:]
    private var activeSet: Set<CharacteristicRef> = []
    /// subscribe 가 접수돼 아직 끝나지 않았다. 알림이 확인 콜백보다 먼저 올 수 있어 전달 대상에 든다
    private var pendingSubscribes: Set<CharacteristicRef> = []
    private var notificationHubs: [CharacteristicRef: EventHub<Data>] = [:]

    package init(peripheralID: PeripheralID, context: SessionContext) {
        self.peripheralID = peripheralID
        self.context = context
        operations = OperationQueue(clock: context.clock, timeoutMilliseconds: Deadlines.operation)
        operations.onPoison = { [weak self] failure in self?.operationsPoisoned(failure) }
        context.adapter.observe { [weak self] adapter in self?.adapterChanged(adapter) }
    }

    /// 시험용: 서비스 목록에 없는 참조를 구독 의도에 넣는다(복원 실패 시험)
    package func injectIntentForTesting(_ characteristic: CharacteristicRef) {
        subscriptions.insert(characteristic)
    }

    /// 앱 시작 등록의 구독 의도를 Disconnected 세션에 심는다. 연결 뒤 Configuring 이 복원한다
    package func seedSubscriptions(_ characteristics: [CharacteristicRef]) {
        subscriptions.formUnion(characteristics)
    }

    /// 등록 기기의 시작 연결. 받을 호출자가 없으므로 반환 전 실패는 `Disconnected(Failed)` 와 진단으로 게시한다
    package func connectRegistered(options: ConnectOptions) async {
        guard !isClosed else { return }
        do {
            try await connect(options: options)
        } catch is CancellationError {
            return
        } catch let error as BLEError {
            failRegisteredStart(error.failure)
        } catch {
            failRegisteredStart(BLEFailure(code: .linkFailed, message: "\(error)"))
        }
    }

    private func failRegisteredStart(_ failure: BLEFailure) {
        guard !isClosed, case .disconnected = state.value else { return }
        publish(.disconnected(reason: .failed(failure)))
        context.events.emit(.diagnostic(code: failure.code, message: "등록 기기 시작 연결이 실패했다: \(failure.message)"))
    }

    package func snapshot() -> SessionSnapshot {
        SessionSnapshot(peripheralID: peripheralID, state: closedState ?? state.value, services: services, subscriptions: subscriptions)
    }

    /// 닫힘: 시작 전 시도는 `CLIENT_CLOSED` 로 끝내고 기한을 거둔다. 열린 세션은 `Disconnected(ClientClosed)` 로 만든 뒤 흐름을 닫는다.
    /// 구독 의도는 남긴다(닫을 때 스냅숏에 그대로 실린다). 멱등이다
    package func close() {
        guard !isClosed else { return }
        isClosed = true
        if let attempt { abort(attempt, AdapterMonitor.closedError()) }
        cancelTimers()
        setup?.cancel()
        setup = nil
        liveGeneration = nil
        resumeOnAdapterReady = false
        pendingSubscribes.removeAll()
        operations.invalidate(GattFailure.closed())
        setActive([])
        if let peripheral, let central = context.central, peripheral.connectionState != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        if case .disconnected = state.value {} else {
            // 닫은 뒤의 전이는 흐름·이벤트로 보장하지 않는다(CANDIDATE-18). 스냅숏만 이 값을 본다
            closedState = .disconnected(reason: .clientClosed)
        }
        for hub in notificationHubs.values { hub.close() }
        disconnectWaiter?.resolve(.success(()))
        disconnectWaiter = nil
        state.close()
        servicesFlow.close()
        activeSubscriptionsFlow.close()
    }

    // MARK: connect 진입

    private enum Admission {
        case alreadyStarted
        case join(ConnectAttempt)
        case new(ConnectAttempt)
    }

    /// 어댑터 판정과 기기 확보는 시간이 걸리지만 진입 함수 중간에 `await` 를 두지 않는다.
    /// 각 단계가 동기로 다음 단계를 잇고, 마지막 줄에서 `startWaiter` 만 기다린다.
    package func connect(options: ConnectOptions) async throws {
        let attempt: ConnectAttempt
        switch try admit(options) {
        case .alreadyStarted:
            return
        case .join(let running):
            try await running.startWaiter.value()
            return
        case .new(let created):
            attempt = created
            begin(created)
        }
        try await withTaskCancellationHandler {
            try await attempt.startWaiter.value()
        } onCancel: {
            Task { @BLECoreActor in self.abort(attempt, CancellationError()) }
        }
    }

    /// 중복 판정(Android `admitConnect` 와 같다). 상태는 바꾸지 않는다.
    private func admit(_ options: ConnectOptions) throws -> Admission {
        if let attempt {
            guard attempt.options == options else { throw Self.optionsConflict }
            return .join(attempt)
        }
        switch state.value {
        case .disconnecting:
            throw BLEError(failure: BLEFailure(code: .connectDuringDisconnect, message: "해제 정리 중이라 연결할 수 없다"))
        case .connecting, .discoveringServices, .configuring, .ready, .recovering:
            guard intent == options else { throw Self.optionsConflict }
            return .alreadyStarted
        case .disconnected:
            break
        }
        generation += 1
        resumeOnAdapterReady = false
        let deadline = options.autoReconnect ? nil : context.clock.nowMilliseconds() + Deadlines.link
        let created = ConnectAttempt(generation: generation, options: options, linkDeadlineAt: deadline)
        attempt = created
        return .new(created)
    }

    private static var optionsConflict: BLEError {
        BLEError(failure: BLEFailure(code: .connectionOptionsConflict, message: "다른 옵션으로 이미 연결 중이다"))
    }

    private func begin(_ attempt: ConnectAttempt) {
        let gate = context.adapter.gate()
        attempt.gate = gate
        Task { @BLECoreActor [weak self] in
            do {
                try await gate.value()
                self?.adapterAdmitted(attempt)
            } catch {
                self?.abort(attempt, error)
            }
        }
    }

    private func adapterAdmitted(_ attempt: ConnectAttempt) {
        guard self.attempt === attempt else { return }
        guard context.adapter.current == .ready, let central = context.central else {
            abort(attempt, BLEError(failure: BLEFailure(code: .adapterUnavailable, message: "판정 뒤 어댑터가 Ready 를 벗어났다")))
            return
        }
        attempt.gate = nil
        let resolver = PeripheralResolver(id: peripheralID, central: central, scanner: context.scanner, clock: context.clock)
        attempt.resolver = resolver
        if let peripheral {
            accept(attempt, peripheral: peripheral, central: central)
            return
        }
        let known = services.map(\.ref.uuid)
        resolver.start(knownServices: known) { [weak self] result in
            guard let self, self.attempt === attempt else { return }
            switch result {
            case .success(let found): self.accept(attempt, peripheral: found, central: central)
            case .failure(let error): self.abort(attempt, error)
            }
        }
    }

    /// 시작 전 시도를 정리한다. 연결 상태는 바꾸지 않는다. 이미 끝났으면 무동작
    private func abort(_ attempt: ConnectAttempt, _ error: any Error) {
        guard self.attempt === attempt else { return }
        self.attempt = nil
        attempt.gate?.cancel()
        attempt.gate = nil
        attempt.resolver?.cancel()
        attempt.resolver = nil
        attempt.startWaiter.resolve(.failure(error))
    }

    /// OS 에 연결을 요청한다. 이 함수가 끝나면 `connect()` 가 반환한다.
    private func accept(_ attempt: ConnectAttempt, peripheral: any PeripheralPort, central: any CentralPort) {
        self.attempt = nil
        attempt.resolver = nil
        self.peripheral = peripheral
        let relay = SessionPeripheralDelegate(session: self, generation: attempt.generation)
        delegateRelay = relay
        peripheral.delegate = relay
        intent = attempt.options
        liveGeneration = attempt.generation
        hasBeenReady = false
        publish(.connecting)
        central.connect(peripheral)
        scheduleLinkDeadline(attempt)
        attempt.startWaiter.resolve(.success(()))
    }

    // MARK: link deadline

    private func scheduleLinkDeadline(_ attempt: ConnectAttempt) {
        linkDeadline?.cancel()
        linkDeadline = nil
        guard let deadlineAt = attempt.linkDeadlineAt else { return }
        let generation = attempt.generation
        let remaining = max(0, deadlineAt - context.clock.nowMilliseconds())
        linkDeadline = Task { @BLECoreActor [weak self, clock = context.clock] in
            do { try await clock.sleep(milliseconds: remaining) } catch { return }
            self?.linkDeadlineReached(generation)
        }
    }

    private func linkDeadlineReached(_ generation: UInt64) {
        guard liveGeneration == generation, case .connecting = state.value else { return }
        linkDeadline = nil
        endLink(.failed(BLEFailure(code: .linkTimeout, message: "\(Deadlines.link)ms 안에 링크가 붙지 않았다")))
        if let peripheral { context.central?.cancelPeripheralConnection(peripheral) }
    }

    // MARK: central 콜백 (`p === peripheral` 과 세대가 맞을 때만)

    private func isLive(_ candidate: any PeripheralPort) -> Bool {
        guard let peripheral, peripheral === candidate, liveGeneration != nil else { return false }
        return true
    }

    package func centralDidConnect(_ candidate: any PeripheralPort) {
        guard isLive(candidate) else { return }
        switch state.value {
        case .connecting, .recovering: break
        default: return
        }
        // 링크가 붙었다. Recovering 에서 붙으면 Connecting 을 거치지 않는다. link deadline 은 여기서 끝나고 서비스 탐색이 시작된다
        linkDeadline?.cancel()
        linkDeadline = nil
        guard let generation = liveGeneration else { return }
        publish(.discoveringServices)
        let created = LinkSetup(
            peripheral: candidate,
            clock: context.clock,
            diagnostic: { [weak self] code, message in self?.context.events.emit(.diagnostic(code: code, message: message)) },
            onFinish: { [weak self] outcome in self?.setupFinished(generation, outcome) }
        )
        setup = created
        created.start()
    }

    /// 링크가 끝났다. 진행 중이던 것을 모두 거두고 상태를 게시한다. 서비스 목록은 비우지 않는다
    package func centralDidDisconnect(_ candidate: any PeripheralPort, error: PortError?) {
        guard isLive(candidate) else { return }
        let failure = Self.linkFailure(error, fallback: "링크가 끊겼다")
        switch state.value {
        case .disconnecting:
            endLink(.requested)
        case .connecting:
            endLink(.failed(failure))
        case .discoveringServices, .configuring, .ready:
            if hasBeenReady, intent?.autoReconnect == true {
                recoverLink(failure, peripheral: candidate)
            } else {
                endLink(.failed(failure))
            }
        case .recovering, .disconnected:
            break
        }
    }

    /// Ready 뒤 링크를 잃었고 autoReconnect 다. 들고 있는 기기에 기한 없는 대기 connect 를 걸고 Recovering 을 유지한다
    private func recoverLink(_ failure: BLEFailure, peripheral: any PeripheralPort) {
        cancelTimers()
        setup?.cancel()
        setup = nil
        publish(.recovering(lastFailure: failure))
        dropLinkBoundState("링크가 끊겨 작업이 무효가 됐다")
        context.central?.connect(peripheral)
    }

    private static func linkFailure(_ error: PortError?, fallback: String) -> BLEFailure {
        PlatformErrorMapping.linkFailure(error, fallback: fallback)
    }

    // MARK: 어댑터 이탈과 복귀

    private func adapterChanged(_ adapter: AdapterState) {
        if adapter == .ready {
            resumeAfterAdapter()
            return
        }
        switch state.value {
        case .connecting, .discoveringServices, .configuring, .ready, .recovering:
            break
        case .disconnecting, .disconnected:
            return
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
        resumeOnAdapterReady = intent?.autoReconnect == true
        abandonLink(.failed(failure))
    }

    /// 어댑터가 돌아왔다. 어댑터 이탈로 끝난 autoReconnect 세션은 한 번 `Connecting` 부터 다시 연결한다
    private func resumeAfterAdapter() {
        guard resumeOnAdapterReady, attempt == nil, case .disconnected = state.value, let options = intent else { return }
        resumeOnAdapterReady = false
        guard case .new(let created)? = try? admit(options) else { return }
        begin(created)
    }

    // MARK: peripheral 콜백 (`p === peripheral` 과 세대가 맞을 때만)

    package func peripheralDidDiscoverServices(_ candidate: any PeripheralPort, generation: UInt64, services: [ServiceRef], error: PortError?) {
        guard isLive(candidate), liveGeneration == generation, case .discoveringServices = state.value else { return }
        setup?.didDiscoverServices(services, error: error)
    }

    package func peripheralDidDiscoverCharacteristics(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        characteristics: [CharacteristicRef],
        for service: ServiceRef,
        error: PortError?
    ) {
        guard isLive(candidate), liveGeneration == generation, case .discoveringServices = state.value else { return }
        setup?.didDiscoverCharacteristics(characteristics, for: service, error: error)
    }

    // MARK: LinkSetup → Configuring → Ready

    private func setupFinished(_ generation: UInt64, _ outcome: LinkSetup.Outcome) {
        guard liveGeneration == generation, case .discoveringServices = state.value else { return }
        let mapping = setup?.portRefs ?? [:]
        setup = nil
        switch outcome {
        case .failure(let failure):
            abandonLink(.failed(failure))
        case .success(let found):
            portRefs = mapping
            publicRefs = [:]
            for (publicRef, portRef) in mapping.sorted(by: { $0.key.instanceIndex < $1.key.instanceIndex }) where publicRefs[portRef] == nil {
                publicRefs[portRef] = publicRef
            }
            services = found
            servicesFlow.send(found)
            context.events.emit(.services(peripheralID: peripheralID, services: found))
            configure(generation)
        }
    }

    /// 늘 거친다. 구독 의도를 복원한다(`configurationStep` 이 있으면 그것으로 바꾼다)
    private func configure(_ generation: UInt64) {
        publish(.configuring)
        configurationDeadline = Task { @BLECoreActor [weak self, clock = context.clock] in
            do { try await clock.sleep(milliseconds: Deadlines.configuration) } catch { return }
            self?.configurationDeadlineReached(generation)
        }
        let done: @BLECoreActor () -> Void = { [weak self] in self?.configurationFinished(generation) }
        if let configurationStep { configurationStep(done) } else { restoreSubscriptions(generation, done: done) }
    }

    private func configurationFinished(_ generation: UInt64) {
        guard liveGeneration == generation, case .configuring = state.value else { return }
        configurationDeadline?.cancel()
        configurationDeadline = nil
        hasBeenReady = true
        publish(.ready)
    }

    private func configurationDeadlineReached(_ generation: UInt64) {
        guard liveGeneration == generation, case .configuring = state.value else { return }
        abandonLink(.failed(BLEFailure(code: .configurationTimeout, message: "\(Deadlines.configuration)ms 안에 설정이 끝나지 않았다")))
    }

    /// 링크를 우리가 끊는다: 실패로 게시하고 OS 에 연결 취소를 요청한다
    private func abandonLink(_ reason: DisconnectReason) {
        endLink(reason)
        if let peripheral { context.central?.cancelPeripheralConnection(peripheral) }
    }

    // MARK: disconnect

    /// 멱등. 이미 끊겼으면 무동작, 해제 중이면 같은 정리를 기다린다. 대기는 마지막 줄의 한 번뿐이다.
    package func disconnect() async {
        let waiter: Waiter<Void>
        switch state.value {
        case .disconnected:
            resumeOnAdapterReady = false
            subscriptions.removeAll()
            if let attempt { abort(attempt, CancellationError()) }
            return
        case .disconnecting:
            guard let running = disconnectWaiter else { return }
            waiter = running
        case .connecting, .discoveringServices, .configuring, .ready, .recovering:
            waiter = beginDisconnect()
        }
        try? await waiter.value()
    }

    private func beginDisconnect() -> Waiter<Void> {
        let waiter = Waiter<Void>()
        disconnectWaiter = waiter
        intent = nil
        subscriptions.removeAll()
        cancelTimers()
        setup?.cancel()
        setup = nil
        publish(.disconnecting)
        dropLinkBoundState("사용자가 연결을 끊었다")
        guard let peripheral, let central = context.central, let generation = liveGeneration else {
            endLink(.requested)
            return waiter
        }
        // 붙지 않은 대기 connect 를 취소하면 OS 는 콜백을 주지 않는다
        let linked = peripheral.connectionState == .connected
        central.cancelPeripheralConnection(peripheral)
        guard linked else {
            endLink(.requested)
            return waiter
        }
        cleanupDeadline = Task { @BLECoreActor [weak self, clock = context.clock] in
            do { try await clock.sleep(milliseconds: Deadlines.disconnectCleanup) } catch { return }
            self?.cleanupDeadlineReached(generation)
        }
        return waiter
    }

    private func cleanupDeadlineReached(_ generation: UInt64) {
        guard liveGeneration == generation, case .disconnecting = state.value else { return }
        cleanupDeadline = nil
        context.events.emit(.diagnostic(
            code: .disconnectCleanupTimeout,
            message: "\(Deadlines.disconnectCleanup)ms 안에 해제 콜백이 오지 않아 강제로 끝낸다"
        ))
        endLink(.requested)
    }

    private func cancelTimers() {
        linkDeadline?.cancel()
        linkDeadline = nil
        configurationDeadline?.cancel()
        configurationDeadline = nil
        cleanupDeadline?.cancel()
        cleanupDeadline = nil
    }

    package func centralDidFailToConnect(_ candidate: any PeripheralPort, error: PortError?) {
        guard isLive(candidate) else { return }
        switch state.value {
        case .connecting, .recovering: break
        default: return
        }
        endLink(.failed(Self.linkFailure(error, fallback: "연결에 실패했다")))
    }

    // MARK: 전이

    private func endLink(_ reason: DisconnectReason) {
        cancelTimers()
        setup?.cancel()
        setup = nil
        liveGeneration = nil
        dropLinkBoundState(Self.invalidationMessage(reason))
        publish(.disconnected(reason: reason))
        disconnectWaiter?.resolve(.success(()))
        disconnectWaiter = nil
    }

    /// 전이마다 세션 상태 흐름과 `BLEEvent.connection` 이 함께 나간다
    private func publish(_ new: ConnectionState) {
        state.send(new)
        context.events.emit(.connection(peripheralID: peripheralID, state: new))
    }
}

// MARK: GATT 명령: read, subscribe, 알림

extension Session {
    /// 진입 검사(states.md §5, §9): 닫힘 → Ready 아님(`NOT_READY`, 연결 시도 중) → 연결 없음(`NOT_CONNECTED`) → 참조 없음. 통과하면 포트 참조
    private func admitGatt(_ characteristic: CharacteristicRef) throws -> CharacteristicRef {
        guard !isClosed else { throw AdapterMonitor.closedError() }
        switch state.value {
        case .ready:
            break
        case .connecting, .discoveringServices, .configuring:
            throw BLEError(failure: BLEFailure(code: .notReady, message: "Ready 가 아니라 명령을 받을 수 없다"))
        case .disconnected, .disconnecting, .recovering:
            throw BLEError(failure: BLEFailure(code: .notConnected, message: "연결이 없다"))
        }
        guard let portRef = portRefs[characteristic] else {
            throw BLEError(failure: BLEFailure(code: .characteristicNotFound, message: "이 기기에 없는 characteristic 이다"))
        }
        return portRef
    }

    /// 대기는 마지막 줄의 한 번뿐이다. 호출자가 취소돼도 작업은 큐 순서대로 끝까지 간다
    package func read(_ characteristic: CharacteristicRef) async throws -> Data {
        let portRef = try admitGatt(characteristic)
        let waiter = operations.submit(.read, characteristic: portRef, start: { [weak self] in
            self?.peripheral?.readValue(for: portRef)
        })
        return try await waiter.value()
    }

    /// 나누기(states.md §8): automatic 은 플랫폼이 한 번에 받는 크기, fixed(n) 은 n. disabled·fixed 가 그 크기를 넘으면 아무것도 보내지 않는다.
    /// 대기는 마지막 줄의 한 번뿐이다. 호출자가 취소돼도 나머지 조각은 끝까지 나간다
    package func write(_ characteristic: CharacteristicRef, value: Data, options: WriteOptions) async throws -> WriteReceipt {
        let portRef = try admitGatt(characteristic)
        guard let port = peripheral else {
            throw BLEError(failure: BLEFailure(code: .notConnected, message: "연결이 없다"))
        }
        let platformMax = port.maximumWriteValueLength(for: options.mode)
        let size: Int
        switch options.chunking {
        case .automatic:
            size = platformMax
        case .disabled:
            size = value.count
        case .fixed(let bytes):
            guard bytes >= 1 else {
                throw BLEError(failure: BLEFailure(code: .payloadTooLarge, message: "나누기 크기는 1 이상이어야 한다"))
            }
            size = bytes
        }
        if options.chunking != .automatic, size > platformMax {
            throw BLEError(failure: BLEFailure(
                code: .payloadTooLarge,
                message: "한 번에 보낼 수 있는 \(platformMax)바이트를 넘는다(\(size)바이트). 나누기를 automatic 으로 바꾼다"
            ))
        }
        let chunks = WriteJob.split(value, limit: size)
        let job = WriteJob(
            chunks: chunks,
            mode: options.mode,
            clock: context.clock,
            canSend: { [weak self] in self?.peripheral?.canSendWriteWithoutResponse ?? false },
            send: { [weak self] chunk in self?.peripheral?.writeValue(chunk, for: portRef, type: options.mode) }
        )
        let waiter = operations.submit(.write, characteristic: portRef, start: { job.start() }, job: job)
        _ = try await waiter.value()
        return WriteReceipt(
            bytesCompleted: value.count,
            chunksCompleted: chunks.count,
            delivery: options.mode == .withResponse ? .remoteAcknowledged : .submittedToPlatform
        )
    }

    /// CCCD 확인 뒤 성공. 이미 구독했어도 CCCD 를 다시 쓴다. 의도와 활성 집합은 작업이 끝날 때 큐가 정한다(호출자 취소와 무관)
    package func subscribe(_ characteristic: CharacteristicRef) async throws {
        let portRef = try admitGatt(characteristic)
        pendingSubscribes.insert(characteristic)
        let waiter = operations.submit(
            .setNotify(enabled: true),
            characteristic: portRef,
            start: { [weak self] in self?.peripheral?.setNotifyValue(true, for: portRef) },
            completion: { [weak self] result in self?.subscribeFinished(characteristic, result) }
        )
        _ = try await waiter.value()
    }

    private func subscribeFinished(_ characteristic: CharacteristicRef, _ result: Result<Data, BLEError>) {
        let stillWanted = pendingSubscribes.remove(characteristic) != nil
        guard stillWanted, case .success = result else { return }
        subscriptions.insert(characteristic)
        setActive(activeSet.union([characteristic]))
    }

    /// 멱등. 의도는 platform 작업보다 먼저 지운다. 켜져 있던 것만 CCCD 를 끄고, 그 실패는 진단으로만 알린다(호출자에게 던지지 않는다)
    package func unsubscribe(_ characteristic: CharacteristicRef) async throws {
        guard !isClosed else { throw AdapterMonitor.closedError() }
        subscriptions.remove(characteristic)
        let wasPending = pendingSubscribes.remove(characteristic) != nil
        guard case .ready = state.value, activeSet.contains(characteristic) || wasPending else { return }
        guard let portRef = portRefs[characteristic] else {
            context.events.emit(.diagnostic(code: .characteristicNotFound, message: "구독 해제 대상이 이 기기에 없다"))
            return
        }
        let waiter = operations.submit(
            .setNotify(enabled: false),
            characteristic: portRef,
            start: { [weak self] in self?.peripheral?.setNotifyValue(false, for: portRef) },
            completion: { [weak self] result in self?.unsubscribeFinished(characteristic, result) }
        )
        do {
            _ = try await waiter.value()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return
        }
    }

    private func unsubscribeFinished(_ characteristic: CharacteristicRef, _ result: Result<Data, BLEError>) {
        setActive(activeSet.subtracting([characteristic]))
        if case .failure(let error) = result, error.failure.code != .operationInvalidated, error.failure.code != .clientClosed {
            context.events.emit(.diagnostic(code: error.failure.code, message: "CCCD 해제가 실패했다: \(error.failure.message)"))
        }
    }

    package func notifications(for characteristic: CharacteristicRef) -> AsyncStream<Data> {
        notificationHub(characteristic).subscribe()
    }

    private func notificationHub(_ characteristic: CharacteristicRef) -> EventHub<Data> {
        if let hub = notificationHubs[characteristic] { return hub }
        let hub = EventHub<Data>()
        if isClosed { hub.close() }
        notificationHubs[characteristic] = hub
        return hub
    }

    // MARK: 콜백 (`p === peripheral` 과 세대가 맞을 때만)

    private func acceptsGattCallback(_ candidate: any PeripheralPort, generation: UInt64) -> Bool {
        guard isLive(candidate), liveGeneration == generation else { return false }
        switch state.value {
        case .configuring, .ready: return true
        default: return false
        }
    }

    /// read 응답과 알림이 같은 콜백으로 온다. 구독 중이면 모두 알림 스트림으로 가고, 진행 중인 read 가 있으면 첫 값이 그 결과다
    package func peripheralDidUpdateValue(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        value: Data?,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        if error == nil, let value, isLive(candidate), liveGeneration == generation {
            notificationTap?(publicRefs[characteristic] ?? characteristic, value)
        }
        guard acceptsGattCallback(candidate, generation: generation), let ref = publicRefs[characteristic] else { return }
        if error == nil, let value, subscriptions.contains(ref) || pendingSubscribes.contains(ref) {
            notificationHubs[ref]?.emit(value)
        }
        operations.didUpdateValue(for: characteristic, value: value, error: error)
    }

    package func peripheralDidWriteValue(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        guard acceptsGattCallback(candidate, generation: generation) else { return }
        if !operations.didWriteValue(for: characteristic, error: error) {
            context.events.emit(.diagnostic(
                code: .gattOperationCallbackMismatch,
                message: "진행 중인 write 가 없는데 쓰기 응답 콜백이 왔다"
            ))
        }
    }

    package func peripheralIsReadyToWriteWithoutResponse(_ candidate: any PeripheralPort, generation: UInt64) {
        guard acceptsGattCallback(candidate, generation: generation) else { return }
        operations.readyToSendWriteWithoutResponse()
    }

    package func peripheralDidUpdateNotificationState(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        isNotifying: Bool,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        guard acceptsGattCallback(candidate, generation: generation) else { return }
        if !operations.didUpdateNotificationState(for: characteristic, isNotifying: isNotifying, error: error) {
            context.events.emit(.diagnostic(
                code: .gattOperationCallbackMismatch,
                message: "진행 중인 작업이 없는데 알림 상태 콜백이 왔다"
            ))
        }
    }

    // MARK: 활성 집합, 폐기, 복원

    private func setActive(_ new: Set<CharacteristicRef>) {
        guard new != activeSet else { return }
        activeSet = new
        activeSubscriptionsFlow.send(new)
    }

    /// 연결에 딸린 것을 버린다: 활성 집합, 접수만 된 구독, 큐. 구독 의도는 남긴다
    private func dropLinkBoundState(_ message: String) {
        pendingSubscribes.removeAll()
        setActive([])
        operations.invalidate(GattFailure.invalidated(message))
    }

    fileprivate static func invalidationMessage(_ reason: DisconnectReason) -> String {
        switch reason {
        case .initial, .requested: "사용자가 연결을 끊었다"
        case .clientClosed: "클라이언트가 닫혔다"
        case .failed(let failure): "연결이 끝나 작업이 무효가 됐다: \(failure.message)"
        }
    }

    /// 큐 기한이 지났다. 그 세대는 다시 쓰지 않고 링크를 끊는다
    private func operationsPoisoned(_ failure: BLEFailure) {
        switch state.value {
        case .configuring, .ready: abandonLink(.failed(failure))
        default: break
        }
    }

    /// Configuring 에서 구독 의도를 하나씩 복원한다. 실패는 `subscriptionRestoreFailed` 이벤트로 알리고 활성 집합에 넣지 않는다.
    /// 새 탐색 결과에 없는 의도는 지운다. 그 밖의 실패는 의도를 남겨 다음 연결에서 다시 시도한다
    private func restoreSubscriptions(_ generation: UInt64, done: @escaping @BLECoreActor () -> Void) {
        let order = subscriptions.sorted { left, right in
            (left.service.uuid.string, left.uuid.string, left.instanceIndex) < (right.service.uuid.string, right.uuid.string, right.instanceIndex)
        }
        restoreNext(order[...], generation, done: done)
    }

    private func restoreNext(_ remaining: ArraySlice<CharacteristicRef>, _ generation: UInt64, done: @escaping @BLECoreActor () -> Void) {
        guard liveGeneration == generation, case .configuring = state.value else { return }
        guard let ref = remaining.first else {
            done()
            return
        }
        let rest = remaining.dropFirst()
        guard subscriptions.contains(ref) else {
            restoreNext(rest, generation, done: done)
            return
        }
        guard let portRef = portRefs[ref] else {
            subscriptions.remove(ref)
            context.events.emit(.subscriptionRestoreFailed(
                peripheralID: peripheralID,
                characteristic: ref,
                failure: BLEFailure(code: .characteristicNotFound, message: "복원할 characteristic 이 새 탐색 결과에 없다")
            ))
            restoreNext(rest, generation, done: done)
            return
        }
        pendingSubscribes.insert(ref)
        _ = operations.submit(
            .setNotify(enabled: true),
            characteristic: portRef,
            start: { [weak self] in self?.peripheral?.setNotifyValue(true, for: portRef) },
            completion: { [weak self] result in
                guard let self else { return }
                self.pendingSubscribes.remove(ref)
                switch result {
                case .success:
                    if self.subscriptions.contains(ref) { self.setActive(self.activeSet.union([ref])) }
                case .failure(let error):
                    let code = error.failure.code
                    if code != .operationInvalidated, code != .clientClosed {
                        self.context.events.emit(.subscriptionRestoreFailed(
                            peripheralID: self.peripheralID, characteristic: ref, failure: error.failure
                        ))
                    }
                }
                self.restoreNext(rest, generation, done: done)
            }
        )
    }
}
