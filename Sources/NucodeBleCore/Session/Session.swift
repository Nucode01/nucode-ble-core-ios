import Foundation

/// 기기 하나의 세션 Runtime. `Disconnected(Initial)` 로 태어난다(docs/v1/ios-design.md §6).
/// 연결 상태의 주인은 `core`(`ConnectionCore.State`)다. 모든 사건을 `ConnectionCore.step` 에 넘기고,
/// 새 상태를 먼저 저장한 뒤 할 일을 목록 순서대로 실행한다.
@BLECoreActor
package final class Session {
    package let peripheralID: PeripheralID
    package let state = StateBroadcaster<ConnectionState>(ConnectionCore.State().phase)
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

    /// 연결 상태의 유일한 주인. 바꾸는 곳은 `dispatch` 하나다
    private var core = ConnectionCore.State()
    package var generation: UInt64 { core.generation }
    /// 마지막으로 OS 가 받아들인 연결 의도
    package var intent: ConnectOptions? { core.intent }
    package var isClosed: Bool { core.closed }

    private var attempt: ConnectAttempt?
    private var linkDeadline: Task<Void, Never>?
    private var setup: LinkSetup?
    private var delegateRelay: SessionPeripheralDelegate?
    private var configurationDeadline: Task<Void, Never>?
    private var cleanupDeadline: Task<Void, Never>?
    private var settleDeadline: Task<Void, Never>?
    private var disconnectWaiter: Waiter<Void>?
    private let context: SessionContext

    // GATT 명령. 참조는 공개(instanceIndex) 쪽과 플랫폼(포트) 쪽을 오간다
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

    /// 시험용: 연결 단계를 Core 상태에 직접 심는다(게시하지 않는다)
    package func injectPhaseForTesting(_ phase: ConnectionState) {
        core.phase = phase
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
            dispatch(.registeredStartFailed(failure: error.failure))
        } catch {
            dispatch(.registeredStartFailed(failure: BLEFailure(code: .linkFailed, message: "\(error)")))
        }
    }

    package func snapshot() -> SessionSnapshot {
        SessionSnapshot(peripheralID: peripheralID, state: ConnectionCore.snapshotPhase(core), services: services, subscriptions: subscriptions)
    }

    /// 닫힘: 시작 전 시도는 `CLIENT_CLOSED` 로 끝내고 기한을 거둔다. 열린 세션은 `Disconnected(ClientClosed)` 로 만든 뒤 흐름을 닫는다.
    /// 구독 의도는 남긴다(닫을 때 스냅숏에 그대로 실린다). 멱등이다
    package func close() {
        dispatch(.close, Inputs(abortError: AdapterMonitor.closedError()))
    }

    // MARK: 사건 → 상태 → 할 일

    /// 할 일을 실행할 때만 필요한 값. 상태 판단에는 쓰이지 않는다
    private struct Inputs {
        var abortError: (any Error)?
        var discovered: (refs: [CharacteristicRef: CharacteristicRef], services: [GATTService])?
    }

    /// 새 상태를 먼저 저장하고 할 일을 순서대로 실행한다. 실행 중 들어온 사건은 저장된 새 상태 위에서 step 한다
    @discardableResult
    private func dispatch(_ event: ConnectionCore.Event, _ inputs: Inputs = Inputs()) -> [ConnectionCore.Effect] {
        let (next, effects) = ConnectionCore.step(core, event)
        core = next
        for effect in effects { perform(effect, inputs) }
        return effects
    }

    private func perform(_ effect: ConnectionCore.Effect, _ inputs: Inputs) {
        switch effect {
        case .publish(let new):
            state.send(new)
            context.events.emit(.connection(peripheralID: peripheralID, state: new))
        case .beginAttempt(let generation, _, _):
            let created = ConnectAttempt(generation: generation)
            attempt = created
            begin(created)
        case .joinAttempt, .rejectConnect, .awaitDisconnect:
            break
        case .abortAttempt(let generation):
            guard let attempt, attempt.generation == generation else { break }
            self.attempt = nil
            attempt.gate?.cancel()
            attempt.gate = nil
            attempt.resolver?.cancel()
            attempt.resolver = nil
            attempt.startWaiter.resolve(.failure(inputs.abortError ?? CancellationError()))
        case .resolveAttempt(let generation):
            guard let attempt, attempt.generation == generation else { break }
            self.attempt = nil
            attempt.resolver = nil
            attempt.startWaiter.resolve(.success(()))
        case .connectPeripheral:
            if let peripheral, let central = context.central { central.connect(peripheral) }
        case .cancelPeripheralConnection:
            if let peripheral { context.central?.cancelPeripheralConnection(peripheral) }
        case .armTimer(let kind, let generation, let milliseconds):
            armTimer(kind, generation, milliseconds)
        case .cancelTimer(let kind):
            cancelTimer(kind)
        case .cancelTimers:
            cancelTimer(.link)
            cancelTimer(.configuration)
            cancelTimer(.cleanup)
            cancelTimer(.adapterSettle)
        case .startDiscovery(let generation):
            guard let peripheral else { break }
            let created = LinkSetup(
                peripheral: peripheral,
                clock: context.clock,
                diagnostic: { [weak self] code, message in self?.context.events.emit(.diagnostic(code: code, message: message)) },
                onFinish: { [weak self] outcome in self?.setupFinished(generation, outcome) }
            )
            setup = created
            created.start()
        case .cancelDiscovery:
            setup?.cancel()
            setup = nil
        case .commitServices:
            setup = nil
            guard let discovered = inputs.discovered else { break }
            portRefs = discovered.refs
            publicRefs = [:]
            for (publicRef, portRef) in discovered.refs.sorted(by: { $0.key.instanceIndex < $1.key.instanceIndex }) where publicRefs[portRef] == nil {
                publicRefs[portRef] = publicRef
            }
            services = discovered.services
            servicesFlow.send(discovered.services)
            context.events.emit(.services(peripheralID: peripheralID, services: discovered.services))
        case .startConfiguration(let generation):
            // 늘 거친다. 구독 의도를 복원한다(`configurationStep` 이 있으면 그것으로 바꾼다)
            let done: @BLECoreActor () -> Void = { [weak self] in self?.dispatch(.configurationFinished(generation: generation)) }
            if let configurationStep { configurationStep(done) } else { restoreSubscriptions(generation, done: done) }
        case .dropLinkBoundState(let message):
            dropLinkBoundState(message)
        case .clearSubscriptionIntent:
            subscriptions.removeAll()
        case .openDisconnectWaiter:
            disconnectWaiter = Waiter<Void>()
        case .resolveDisconnectWaiter:
            disconnectWaiter?.resolve(.success(()))
            disconnectWaiter = nil
        case .diagnostic(let code, let message):
            context.events.emit(.diagnostic(code: code, message: message))
        case .closeGattState:
            pendingSubscribes.removeAll()
            operations.invalidate(GattFailure.closed())
            setActive([])
        case .releasePeripheralOnClose:
            if let peripheral, let central = context.central, peripheral.connectionState != .disconnected {
                central.cancelPeripheralConnection(peripheral)
            }
        case .closeFlows:
            for hub in notificationHubs.values { hub.close() }
            state.close()
            servicesFlow.close()
            activeSubscriptionsFlow.close()
        }
    }

    // MARK: connect 진입

    /// 어댑터 판정과 기기 확보는 시간이 걸리지만 진입 함수 중간에 `await` 를 두지 않는다.
    /// 각 단계가 동기로 다음 단계를 잇고, 마지막 줄에서 `startWaiter` 만 기다린다.
    package func connect(options: ConnectOptions) async throws {
        var joined = false
        var created = false
        for effect in dispatch(.connect(options: options, now: context.clock.nowMilliseconds())) {
            switch effect {
            case .rejectConnect(let failure): throw BLEError(failure: failure)
            case .joinAttempt: joined = true
            case .beginAttempt: created = true
            default: break
            }
        }
        guard let attempt else { return }
        if joined {
            try await attempt.startWaiter.value()
            return
        }
        guard created else { return }
        try await withTaskCancellationHandler {
            try await attempt.startWaiter.value()
        } onCancel: {
            Task { @BLECoreActor in self.abort(attempt, CancellationError()) }
        }
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
        let recheck = AdapterCore.recheck(context.adapter.current)
        guard recheck == nil, let central = context.central else {
            abort(attempt, BLEError(failure: recheck ?? AdapterCore.leftReady))
            return
        }
        attempt.gate = nil
        let resolver = PeripheralResolver(id: peripheralID, central: central, scanner: context.scanner, clock: context.clock)
        attempt.resolver = resolver
        if let peripheral {
            accept(attempt, peripheral: peripheral)
            return
        }
        let known = services.map(\.ref.uuid)
        resolver.start(knownServices: known) { [weak self] result in
            guard let self, self.attempt === attempt else { return }
            switch result {
            case .success(let found): self.accept(attempt, peripheral: found)
            case .failure(let error): self.abort(attempt, error)
            }
        }
    }

    /// 시작 전 시도를 정리한다. 연결 상태는 바꾸지 않는다. 이미 끝났으면 무동작
    private func abort(_ attempt: ConnectAttempt, _ error: any Error) {
        guard self.attempt === attempt else { return }
        dispatch(.attemptFailed(generation: attempt.generation), Inputs(abortError: error))
    }

    /// 기기를 확보했다. 붙인 뒤 OS 에 연결을 요청하는 것은 Core 가 낸 할 일이다
    private func accept(_ attempt: ConnectAttempt, peripheral: any PeripheralPort) {
        self.peripheral = peripheral
        let relay = SessionPeripheralDelegate(session: self, generation: attempt.generation)
        delegateRelay = relay
        peripheral.delegate = relay
        dispatch(.attemptAccepted(generation: attempt.generation, now: context.clock.nowMilliseconds()))
    }

    // MARK: 기한

    private func armTimer(_ kind: ConnectionCore.TimerKind, _ generation: UInt64, _ milliseconds: Int) {
        cancelTimer(kind)
        let task = Task { @BLECoreActor [weak self, clock = context.clock] in
            do { try await clock.sleep(milliseconds: milliseconds) } catch { return }
            self?.dispatch(.timerFired(kind: kind, generation: generation))
        }
        switch kind {
        case .link: linkDeadline = task
        case .configuration: configurationDeadline = task
        case .cleanup: cleanupDeadline = task
        case .adapterSettle: settleDeadline = task
        }
    }

    private func cancelTimer(_ kind: ConnectionCore.TimerKind) {
        switch kind {
        case .link:
            linkDeadline?.cancel()
            linkDeadline = nil
        case .configuration:
            configurationDeadline?.cancel()
            configurationDeadline = nil
        case .cleanup:
            cleanupDeadline?.cancel()
            cleanupDeadline = nil
        case .adapterSettle:
            settleDeadline?.cancel()
            settleDeadline = nil
        }
    }

    // MARK: central 콜백 (`p === peripheral` 과 세대가 맞을 때만)

    private func isLive(_ candidate: any PeripheralPort) -> Bool {
        guard let peripheral, peripheral === candidate, core.live != nil else { return false }
        return true
    }

    package func centralDidConnect(_ candidate: any PeripheralPort) {
        dispatch(.linkConnected(sameDevice: isLive(candidate)))
    }

    /// 링크가 끝났다. 진행 중이던 것을 모두 거두고 상태를 게시한다. 서비스 목록은 비우지 않는다
    package func centralDidDisconnect(_ candidate: any PeripheralPort, error: PortError?) {
        let failure = PlatformErrorMapping.linkFailure(error, fallback: "링크가 끊겼다")
        dispatch(.linkDisconnected(sameDevice: isLive(candidate), failure: failure))
    }

    package func centralDidFailToConnect(_ candidate: any PeripheralPort, error: PortError?) {
        let failure = PlatformErrorMapping.linkFailure(error, fallback: "연결에 실패했다")
        dispatch(.linkFailedToConnect(sameDevice: isLive(candidate), failure: failure))
    }

    // MARK: 어댑터 이탈과 복귀

    private func adapterChanged(_ adapter: AdapterState) {
        dispatch(.adapterChanged(adapter, now: context.clock.nowMilliseconds()))
    }

    // MARK: peripheral 콜백 (`p === peripheral` 과 세대가 맞을 때만)

    package func peripheralDidDiscoverServices(_ candidate: any PeripheralPort, generation: UInt64, services: [ServiceRef], error: PortError?) {
        guard ConnectionCore.acceptsDiscoveryCallback(core, sameDevice: isLive(candidate), generation: generation) else { return }
        setup?.didDiscoverServices(services, error: error)
    }

    package func peripheralDidDiscoverCharacteristics(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        characteristics: [CharacteristicRef],
        for service: ServiceRef,
        error: PortError?
    ) {
        guard ConnectionCore.acceptsDiscoveryCallback(core, sameDevice: isLive(candidate), generation: generation) else { return }
        setup?.didDiscoverCharacteristics(characteristics, for: service, error: error)
    }

    // MARK: LinkSetup → Configuring → Ready

    private func setupFinished(_ generation: UInt64, _ outcome: LinkSetup.Outcome) {
        switch outcome {
        case .failure(let failure):
            dispatch(.discoveryFinished(generation: generation, failure: failure))
        case .success(let found):
            dispatch(
                .discoveryFinished(generation: generation, failure: nil),
                Inputs(discovered: (refs: setup?.portRefs ?? [:], services: found))
            )
        }
    }

    // MARK: disconnect

    /// 멱등. 이미 끊겼으면 무동작, 해제 중이면 같은 정리를 기다린다. 대기는 마지막 줄의 한 번뿐이다.
    package func disconnect() async {
        let linked = peripheral?.connectionState == .connected
        let effects = dispatch(
            .disconnect(hasLinkTarget: peripheral != nil && context.central != nil, linked: linked),
            Inputs(abortError: CancellationError())
        )
        guard effects.contains(where: { if case .awaitDisconnect = $0 { true } else { false } }) else { return }
        try? await disconnectWaiter?.value()
    }

    /// 큐 기한이 지났다. 그 세대는 다시 쓰지 않고 링크를 끊는다
    private func operationsPoisoned(_ failure: BLEFailure) {
        dispatch(.operationsPoisoned(failure: failure))
    }
}

// MARK: GATT 명령: read, subscribe, 알림

extension Session {
    /// 진입 검사(states.md §5 명령 진입 검사 순서): 닫힘 → 어댑터(§6) → 세션 Ready 아님(`NOT_READY`) → 참조 없음. 통과하면 포트 참조.
    /// 판정은 `ConnectionCore.gattAdmission` 이 한다. 어댑터가 `unknown` 일 때만 판정을 기다리고(§6, connect 와 같은 대기),
    /// 기다린 뒤의 확인은 모두 대기 이후에 한다. 확인과 큐 접수 사이에는 `await` 가 없다
    private func admitGatt(_ characteristic: CharacteristicRef) async throws -> CharacteristicRef {
        if case .awaitAdapterDecision = ConnectionCore.gattAdmission(core, adapter: context.adapter.current) {
            let gate = context.adapter.gate()
            try await withTaskCancellationHandler {
                try await gate.value()
            } onCancel: {
                Task { @BLECoreActor in gate.cancel() }
            }
        }
        switch ConnectionCore.gattAdmission(core, adapter: context.adapter.current) {
        case .admit:
            break
        case .reject(let failure):
            throw BLEError(failure: failure)
        case .awaitAdapterDecision:
            // 판정을 받은 뒤 다시 unknown 이 됐다
            throw BLEError(failure: AdapterCore.leftReady)
        }
        guard let portRef = portRefs[characteristic] else {
            throw BLEError(failure: BLEFailure(code: .characteristicNotFound, message: "이 기기에 없는 characteristic 이다"))
        }
        return portRef
    }

    /// 작업 대기는 마지막 줄의 한 번뿐이다(앞의 진입 검사는 어댑터가 `unknown` 일 때만 기다린다). 호출자가 취소돼도 접수된 작업은 큐 순서대로 끝까지 간다
    package func read(_ characteristic: CharacteristicRef) async throws -> Data {
        let portRef = try await admitGatt(characteristic)
        let waiter = operations.submit(.read, characteristic: portRef, start: { [weak self] in
            self?.peripheral?.readValue(for: portRef)
        })
        return try await waiter.value()
    }

    /// 나누기(states.md §8): automatic 은 플랫폼이 한 번에 받는 크기, fixed(n) 은 n. disabled·fixed 가 그 크기를 넘으면 아무것도 보내지 않는다.
    /// 작업 대기는 마지막 줄의 한 번뿐이다(앞의 진입 검사는 어댑터가 `unknown` 일 때만 기다린다). 호출자가 취소돼도 나머지 조각은 끝까지 나간다
    package func write(_ characteristic: CharacteristicRef, value: Data, options: WriteOptions) async throws -> WriteReceipt {
        let portRef = try await admitGatt(characteristic)
        guard let port = peripheral else {
            // 방어 검사: Ready 면 기기 객체가 있다(states.md §5 NOT_CONNECTED)
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
        let portRef = try await admitGatt(characteristic)
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
        guard ConnectionCore.isReady(core), activeSet.contains(characteristic) || wasPending else { return }
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
        ConnectionCore.acceptsGattCallback(core, sameDevice: isLive(candidate), generation: generation)
    }

    /// read 응답과 알림이 같은 콜백으로 온다. 구독 중이면 모두 알림 스트림으로 가고, 진행 중인 read 가 있으면 첫 값이 그 결과다
    package func peripheralDidUpdateValue(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        value: Data?,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        if error == nil, let value, isLive(candidate), core.live == generation {
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

    /// Configuring 에서 구독 의도를 하나씩 복원한다. 실패는 `subscriptionRestoreFailed` 이벤트로 알리고 활성 집합에 넣지 않는다.
    /// 새 탐색 결과에 없는 의도는 지운다. 그 밖의 실패는 의도를 남겨 다음 연결에서 다시 시도한다
    private func restoreSubscriptions(_ generation: UInt64, done: @escaping @BLECoreActor () -> Void) {
        let order = subscriptions.sorted { left, right in
            (left.service.uuid.string, left.uuid.string, left.instanceIndex) < (right.service.uuid.string, right.uuid.string, right.instanceIndex)
        }
        restoreNext(order[...], generation, done: done)
    }

    private func restoreNext(_ remaining: ArraySlice<CharacteristicRef>, _ generation: UInt64, done: @escaping @BLECoreActor () -> Void) {
        guard ConnectionCore.isConfiguring(core, generation: generation) else { return }
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
