import Foundation

/// 공개 client: 상태 없는 Sendable view. 상태는 `BLERuntime` 이 `@BLECoreActor` 위에서 갖는다.
/// 공개 생성자는 CoreBluetooth 드라이버와 `Bundle.main` 환경을 쓴다. `package` 생성자는 시험이 포트·시계·환경을 주입한다.
public final class BLEClient: Sendable {
    package let runtime: BLERuntime

    /// CoreBluetooth 로 잇는다. manager 는 `start()` 에서 만든다. 같은 프로세스에서 같은 `restoreIdentifier` 를 두 번 쓰면 trap 한다.
    public convenience init(options: BLEOptions = BLEOptions()) {
        RestoreIdentifierGuard.claimOrTrap(options.restoreIdentifier)
        let identifier = options.restoreIdentifier
        self.init(options: options, environment: .bundle(.main)) {
            CoreBluetoothCentral(restoreIdentifier: identifier)
        }
    }

    package init(
        options: BLEOptions = BLEOptions(),
        environment: BLEEnvironment,
        clock: any BLEClock = ScaledClock.realtime,
        centralFactory: @escaping @BLECoreActor @Sendable () -> any CentralPort
    ) {
        runtime = runOnCore {
            BLERuntime(options: options, environment: environment, clock: clock, centralFactory: centralFactory)
        }
    }

    /// `start()` 전에는 `unknown`
    public var adapterStates: AsyncStream<AdapterState> {
        runOnCore { [runtime] in runtime.adapter.states.subscribe() }
    }

    public var scanResults: AsyncStream<ScanResult> {
        runOnCore { [runtime] in runtime.scanner.results.subscribe() }
    }

    /// `Idle` · `Scanning` · `Idle(Failed:<코드>)`. 구독하면 현재 값을 먼저 준다
    public var scanStates: AsyncStream<ScanState> {
        runOnCore { [runtime] in runtime.scanner.states.subscribe() }
    }

    public var events: AsyncStream<BLEEvent> {
        runOnCore { [runtime] in runtime.events.subscribe() }
    }

    // MARK: 앱 시작 등록 (iOS 전용, `start()` 전에만. 뒤에 부르면 프로그래머 오류로 trap 한다)

    /// 기기를 등록한다. `poweredOn` 에서 `connect(options)` 와 같은 경로로 연결하고, 복원된 기기는 그 경로가 이어받는다
    public func register(_ peripheralID: PeripheralID, options: ConnectOptions, subscribe: [CharacteristicRef]) {
        runOnCore { [runtime] in runtime.register(peripheralID, options: options, subscribe: subscribe) }
    }

    /// 스캔 복원 때 되살릴 조건. 등록하지 않으면 복원된 스캔은 멈춘다
    public func registerScan(_ request: ScanRequest) {
        runOnCore { [runtime] in runtime.registerScan(request) }
    }

    /// 등록된 characteristic 의 알림을 세션 단계와 무관하게 `queue` 에서 받는다
    public func onNotification(
        queue: DispatchQueue,
        _ handler: @escaping @Sendable (PeripheralID, CharacteristicRef, Data) -> Void
    ) {
        runOnCore { [runtime] in runtime.onNotification(queue: queue, handler) }
    }

    /// throw 하지 않는다. 사용 설명 키가 없으면 manager 를 만들지 않고 `unauthorized(canRequest: false)` 를 게시한다.
    public func start() {
        runOnCore { [runtime] in runtime.start() }
    }

    public func startScan(request: ScanRequest) async throws {
        try await runtime.startScan(request)
    }

    public func stopScan() async {
        runOnCore { [runtime] in runtime.stopScan() }
    }

    public func session(for peripheralID: PeripheralID) throws -> any BLESession {
        let session = try runOnCore { [runtime] in Result { try runtime.session(for: peripheralID) } }.get()
        return SessionHandle(session: session, runtime: runtime)
    }

    /// 세션을 만들고 연결 시도를 시작한다. 반환은 "시도가 시작됐다"는 뜻이다(contract/states.md §4)
    public func connect(_ peripheralID: PeripheralID, options: ConnectOptions) async throws -> any BLESession {
        let session = try session(for: peripheralID)
        try await session.connect(options: options)
        return session
    }

    public func snapshot() async -> ClientSnapshot {
        await runtime.snapshot()
    }

    public func close() {
        runOnCore { [runtime] in runtime.close() }
    }
}
