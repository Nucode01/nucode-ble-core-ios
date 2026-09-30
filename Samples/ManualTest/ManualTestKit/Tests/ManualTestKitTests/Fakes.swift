import Foundation
import ManualTestDomain
import os

/// 사건을 손으로 흘려 넣는 게이트웨이. 명령은 기록하고, `failures` 에 있으면 그 코드로 던진다
final class FakeGateway: BleGateway {
    let events: AsyncStream<GatewayEvent>
    private let continuation: AsyncStream<GatewayEvent>.Continuation
    private let state = OSAllocatedUnfairLock(initialState: Recorded())

    struct Recorded {
        var calls: [String] = []
        var failures: [String: GatewayError] = [:]
        var startedWith: DeviceRegistration??
        var snapshot = GatewaySnapshot(adapter: .unknown, scanning: false, sessions: [])
        var readValue = Data([0x01, 0x02])
    }

    init() {
        (events, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
    }

    var calls: [String] { state.withLock { $0.calls } }
    var startedWith: DeviceRegistration?? { state.withLock { $0.startedWith } }
    func fail(_ call: String, code: String) { state.withLock { $0.failures[call] = GatewayError(code: code, message: "fake") } }
    func succeed(_ call: String) { state.withLock { $0.failures[call] = nil } }
    func setSnapshot(_ snapshot: GatewaySnapshot) { state.withLock { $0.snapshot = snapshot } }
    func emit(_ event: GatewayEvent) { continuation.yield(event) }
    func finish() { continuation.finish() }

    private func call(_ name: String, _ detail: String = "") throws {
        let failure = state.withLock { s -> GatewayError? in
            s.calls.append(detail.isEmpty ? name : "\(name) \(detail)")
            return s.failures[name]
        }
        if let failure { throw failure }
    }

    func start(registration: DeviceRegistration?) {
        state.withLock { $0.startedWith = .some(registration) }
    }

    func snapshot() async -> GatewaySnapshot { state.withLock { $0.snapshot } }
    func startScan(_ criteria: ScanCriteria) async throws { try call("startScan", criteria.label) }
    func stopScan() async { try? call("stopScan") }
    func connect(_ id: DeviceId, autoReconnect: Bool) async throws { try call("connect", "\(id) auto=\(autoReconnect)") }
    func disconnect(_ id: DeviceId) async { try? call("disconnect", id.rawValue) }
    func read(_ id: DeviceId, _ c: ProbeCharacteristic) async throws -> Data {
        try call("read", c.rawValue)
        return state.withLock { $0.readValue }
    }
    func write(_ id: DeviceId, _ c: ProbeCharacteristic, value: Data) async throws -> Int {
        try call("write", "\(c.rawValue) \(value.hex)")
        return value.count
    }
    func subscribe(_ id: DeviceId, _ c: ProbeCharacteristic) async throws { try call("subscribe", c.rawValue) }
    func unsubscribe(_ id: DeviceId, _ c: ProbeCharacteristic) async throws { try call("unsubscribe", c.rawValue) }
}

final class MemoryLogStore: EventLogStore {
    private let entries: OSAllocatedUnfairLock<[LogEntry]>
    init(_ initial: [LogEntry] = []) { entries = OSAllocatedUnfairLock(initialState: initial) }
    var saved: [LogEntry] { entries.withLock { $0 } }
    func load() throws -> [LogEntry] { saved }
    func append(_ entry: LogEntry) throws { entries.withLock { $0.append(entry) } }
    func clear() throws { entries.withLock { $0.removeAll() } }
}

final class MemoryRegistrationStore: RegistrationStore {
    private let value: OSAllocatedUnfairLock<DeviceRegistration?>
    init(_ initial: DeviceRegistration? = nil) { value = OSAllocatedUnfairLock(initialState: initial) }
    func load() throws -> DeviceRegistration? { value.withLock { $0 } }
    func save(_ registration: DeviceRegistration?) throws { value.withLock { $0 = registration } }
}

/// 부를 때마다 1초씩 간다
final class SteppingClock: Clock {
    private let t = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_800_000_000))
    func now() -> Date { t.withLock { $0 = $0.addingTimeInterval(1); return $0 } }
}

/// 시험이 옮기는 시계
final class ManualClock: Clock {
    private let t: OSAllocatedUnfairLock<Date>
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { t = OSAllocatedUnfairLock(initialState: start) }
    func now() -> Date { t.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

final class MemoryChecklistStore: ChecklistStore {
    private let value = OSAllocatedUnfairLock(initialState: (results: [Int: ChecklistResult](), saves: 0))
    var saves: Int { value.withLock { $0.saves } }
    func load() throws -> [Int: ChecklistResult] { value.withLock { $0.results } }
    func save(_ results: [Int: ChecklistResult]) throws {
        value.withLock { $0 = (results, $0.saves + 1) }
    }
}
