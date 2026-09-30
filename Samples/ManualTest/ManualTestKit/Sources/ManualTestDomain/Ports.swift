import Foundation

// MARK: 포트. 구현은 Infrastructure(실제)와 시험(가짜)이 한다

/// 게이트웨이가 알리는 사건. 라이브러리의 여러 스트림을 한 줄로 합친 것이다
public enum GatewayEvent: Hashable, Sendable {
    case adapter(AdapterStatus)
    case scan(ScanStatus)
    case discovered(DiscoveredDevice)
    case link(DeviceId, LinkState)
    case services(DeviceId, count: Int)
    case activeSubscriptions(DeviceId, Set<ProbeCharacteristic>)
    case notification(DeviceId, ProbeCharacteristic, Data)
    case subscriptionRestoreFailed(DeviceId, characteristic: String, code: String)
    case diagnostic(code: String, message: String)
}

/// BLE 라이브러리 입구. 명령 실패는 `GatewayError` 로 던진다
public protocol BleGateway: AnyObject, Sendable {
    /// 수집자는 하나. `start` 전 사건도 버퍼에 남는다
    var events: AsyncStream<GatewayEvent> { get }
    /// 앱 시작 등록 뒤 시작한다. 한 번만, 앱 실행 직후(didFinishLaunching)에 동기로 부른다
    func start(registration: DeviceRegistration?)
    func snapshot() async -> GatewaySnapshot

    func startScan(_ criteria: ScanCriteria) async throws
    func stopScan() async
    func connect(_ id: DeviceId, autoReconnect: Bool) async throws
    func disconnect(_ id: DeviceId) async
    func read(_ id: DeviceId, _ characteristic: ProbeCharacteristic) async throws -> Data
    /// 보낸 바이트 수
    func write(_ id: DeviceId, _ characteristic: ProbeCharacteristic, value: Data) async throws -> Int
    func subscribe(_ id: DeviceId, _ characteristic: ProbeCharacteristic) async throws
    func unsubscribe(_ id: DeviceId, _ characteristic: ProbeCharacteristic) async throws
}

public protocol EventLogStore: Sendable {
    func load() throws -> [LogEntry]
    func append(_ entry: LogEntry) throws
    func clear() throws
}

public protocol ChecklistStore: Sendable {
    func load() throws -> [Int: ChecklistResult]
    func save(_ results: [Int: ChecklistResult]) throws
}

public protocol RegistrationStore: Sendable {
    func load() throws -> DeviceRegistration?
    func save(_ registration: DeviceRegistration?) throws
}

public protocol Clock: Sendable {
    func now() -> Date
}
