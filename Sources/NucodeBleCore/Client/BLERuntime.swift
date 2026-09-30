import Foundation

/// core 의 명령 입구와 조립 지점(docs/v1/ios-design.md §5). 모든 것이 `@BLECoreActor` 위에서 동기로 돈다.
@BLECoreActor
package final class BLERuntime: CentralPortDelegate {
    package let adapter: AdapterMonitor
    package let events: EventHub<BLEEvent>
    package let registry: SessionRegistry
    package let scanner: BLEScanner
    private let sessionContext: SessionContext
    package let registrations = Registrations()
    private lazy var restoreTranslator = RestoreTranslator(
        registrations: registrations,
        registry: registry,
        scanner: scanner,
        central: { [weak self] in self?.sessionContext.central }
    )
    private var registeredStarted = false

    private let options: BLEOptions
    private let environment: BLEEnvironment
    private let centralFactory: @BLECoreActor @Sendable () -> any CentralPort
    private var started = false
    private(set) package var isClosed = false
    private var frozenSnapshot: ClientSnapshot?

    package init(
        options: BLEOptions,
        environment: BLEEnvironment,
        clock: any BLEClock,
        centralFactory: @escaping @BLECoreActor @Sendable () -> any CentralPort
    ) {
        self.options = options
        self.environment = environment
        self.centralFactory = centralFactory
        let adapter = AdapterMonitor(clock: clock)
        let events = EventHub<BLEEvent>()
        let scanner = BLEScanner()
        let context = SessionContext(adapter: adapter, scanner: scanner, events: events, clock: clock)
        self.adapter = adapter
        self.events = events
        self.scanner = scanner
        sessionContext = context
        registry = SessionRegistry(context: context)
    }

    // MARK: 앱 시작 등록 (start() 전에만, 뒤면 프로그래머 오류로 trap — CANDIDATE-25)

    package func register(_ id: PeripheralID, options: ConnectOptions, subscribe: [CharacteristicRef]) {
        precondition(!started, "register 는 start() 전에만 부른다")
        registrations.add(.init(id: id, options: options, subscribe: subscribe))
        let session = registry.session(for: id)
        session.seedSubscriptions(subscribe)
        session.notificationTap = { [registrations] characteristic, value in
            registrations.deliver(id: id, characteristic: characteristic, value: value)
        }
    }

    package func registerScan(_ request: ScanRequest) {
        precondition(!started, "registerScan 은 start() 전에만 부른다")
        registrations.setScan(request)
    }

    package func onNotification(queue: DispatchQueue, _ handler: @escaping @Sendable (PeripheralID, CharacteristicRef, Data) -> Void) {
        precondition(!started, "onNotification 은 start() 전에만 부른다")
        registrations.setHandler(queue: queue, handler)
    }

    /// 어댑터가 처음 Ready 가 되면 등록 기기마다 앱의 `connect` 와 같은 경로를 시작한다(한 번뿐)
    private func startRegisteredIfReady() {
        guard !registeredStarted, !isClosed, adapter.current == .ready else { return }
        registeredStarted = true
        for device in registrations.orderedDevices {
            let session = registry.session(for: device.id)
            Task { @BLECoreActor in await session.connectRegistered(options: device.options) }
        }
    }

    // MARK: 시작

    /// throw 하지 않는다. 두 번째부터는 무동작. manager 생성은 맨 마지막이다(CANDIDATE-25).
    package func start() {
        guard !started, !isClosed else { return }
        started = true
        guard environment.hasBluetoothUsageDescription else {
            adapter.publishMissingUsageDescription()
            return
        }
        if options.restoreIdentifier != nil {
            precondition(
                environment.hasBluetoothCentralBackgroundMode,
                "상태 복원 옵션에는 UIBackgroundModes 의 bluetooth-central 이 필요하다"
            )
        }
        let central = centralFactory()
        central.delegate = self
        sessionContext.central = central
        adapter.attach(central)
        scanner.attach(central, adapter: adapter.current)
        startRegisteredIfReady()
    }

    // MARK: 명령 입구

    /// 명령이 진행해도 되는지 판정한다. 닫혔으면 `CLIENT_CLOSED`. 대기는 마지막 줄의 한 번뿐이다.
    package func requireUsableAdapter() async throws {
        let gate = adapter.gate()
        try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            Task { @BLECoreActor in gate.cancel() }
        }
    }

    /// 어댑터 판정(connect 와 같다, CANDIDATE-20) 뒤에 스캔을 시작한다.
    /// 대기 뒤의 확인은 모두 대기 이후에 하고, 확인과 시작 사이에는 `await` 가 없다.
    package func startScan(_ request: ScanRequest) async throws {
        let gate = adapter.gate()
        try await withTaskCancellationHandler {
            try await gate.value()
        } onCancel: {
            Task { @BLECoreActor in gate.cancel() }
        }
        guard !isClosed else { throw AdapterMonitor.closedError() }
        if let failure = AdapterCore.recheck(adapter.current) {
            throw BLEError(failure: failure)
        }
        try scanner.start(request)
    }

    /// 멱등. 닫힌 뒤에도 성공이다
    package func stopScan() {
        scanner.stop()
    }

    package func session(for id: PeripheralID) throws -> Session {
        guard !isClosed else { throw AdapterMonitor.closedError() }
        return registry.session(for: id)
    }

    /// 닫힘 확인 뒤 세션의 연결 진입으로 넘긴다. 진입 계층은 마지막 줄의 대기 하나뿐이다.
    package func connect(_ session: Session, options: ConnectOptions) async throws {
        guard !isClosed else { throw AdapterMonitor.closedError() }
        try await session.connect(options: options)
    }

    /// 닫힌 뒤에는 세션이 이미 정리됐으니 무동작
    package func disconnect(_ session: Session) async {
        guard !isClosed else { return }
        await session.disconnect()
    }

    // MARK: 스냅숏과 닫기

    package func snapshot() -> ClientSnapshot {
        if let frozenSnapshot { return frozenSnapshot }
        return ClientSnapshot(adapter: adapter.current, scanning: scanner.isUserScanning, sessions: registry.snapshots())
    }

    /// 멱등. 스캔을 멈추고 세션을 닫은 뒤(구독 의도는 남는다) 그 순간의 스냅숏을 고정하고 모든 흐름을 끝낸다.
    package func close() {
        guard !isClosed else { return }
        isClosed = true
        let adapterAtClose = adapter.current
        scanner.close()
        registry.close()
        frozenSnapshot = ClientSnapshot(adapter: adapterAtClose, scanning: scanner.isUserScanning, sessions: registry.snapshots())
        adapter.close()
        events.close()
    }

    // MARK: CentralPortDelegate

    package func centralDidUpdateState(_ central: any CentralPort) {
        restoreTranslator.centralStateChanged(central.state)
        adapter.refresh()
        scanner.adapterChanged(adapter.current)
        startRegisteredIfReady()
    }

    package func central(_ central: any CentralPort, didDiscover peripheral: any PeripheralPort, advertisement: AdvertisementData, rssi: Int) {
        scanner.didDiscover(peripheral, advertisement: advertisement, rssi: rssi)
    }
    package func central(_ central: any CentralPort, didConnect peripheral: any PeripheralPort) {
        registry.sessions[peripheral.id]?.centralDidConnect(peripheral)
    }
    package func central(_ central: any CentralPort, didFailToConnect peripheral: any PeripheralPort, error: PortError?) {
        registry.sessions[peripheral.id]?.centralDidFailToConnect(peripheral, error: error)
    }
    package func central(_ central: any CentralPort, didDisconnect peripheral: any PeripheralPort, error: PortError?) {
        registry.sessions[peripheral.id]?.centralDidDisconnect(peripheral, error: error)
    }
    package func central(_ central: any CentralPort, willRestoreState peripherals: [any PeripheralPort]) {
        restoreTranslator.willRestoreState(peripherals)
    }
}
