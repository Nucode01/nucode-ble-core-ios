import Foundation

/// `BLEClient` 구현: 상태 없는 Sendable view. 상태는 `BLERuntime` 이 `@BLECoreActor` 위에서 갖는다.
/// 공개 생성은 `Factory/BLEClientFactory.swift` 가 한다(CoreBluetooth 드라이버와 `Bundle.main` 환경을 쓴다). `package` 생성자는 시험이 포트·시계·환경을 주입한다.
package final class DefaultBLEClient: BLEClient {
    package let runtime: BLERuntime

    package init(
        options: BLEOptions = BLEOptions(),
        environment: BLEEnvironment,
        clock: any BLEClock,
        centralFactory: @escaping @BLECoreActor @Sendable () -> any CentralPort
    ) {
        runtime = runOnCore {
            BLERuntime(options: options, environment: environment, clock: clock, centralFactory: centralFactory)
        }
    }

    public var adapterStates: AsyncStream<AdapterState> {
        runOnCore { [runtime] in runtime.adapter.states.subscribe() }
    }

    public var scanResults: AsyncStream<ScanResult> {
        runOnCore { [runtime] in runtime.scanner.results.subscribe() }
    }

    public var scanStates: AsyncStream<ScanState> {
        runOnCore { [runtime] in runtime.scanner.states.subscribe() }
    }

    public var events: AsyncStream<BLEEvent> {
        runOnCore { [runtime] in runtime.events.subscribe() }
    }

    // MARK: 앱 시작 등록 (iOS 전용)

    public func register(_ peripheralID: PeripheralID, options: ConnectOptions, subscribe: [CharacteristicRef]) {
        runOnCore { [runtime] in runtime.register(peripheralID, options: options, subscribe: subscribe) }
    }

    public func registerScan(_ request: ScanRequest) {
        runOnCore { [runtime] in runtime.registerScan(request) }
    }

    public func onNotification(
        queue: DispatchQueue,
        _ handler: @escaping @Sendable (PeripheralID, CharacteristicRef, Data) -> Void
    ) {
        runOnCore { [runtime] in runtime.onNotification(queue: queue, handler) }
    }

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
