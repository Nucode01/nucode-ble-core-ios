import Foundation
import NucodeBleCore

// region guide:inject-client
/// client 를 init 으로 받는 앱 객체. 앱은 `BLEClientFactory.make()` 를, 시험은 가짜를 넘긴다
@MainActor
final class AdapterBanner {
    private(set) var text = ""
    private let client: any BLEClient
    private var task: Task<Void, Never>?

    init(client: any BLEClient) {
        self.client = client
    }

    func begin() {
        let states = client.adapterStates
        task = Task { [weak self] in
            for await state in states {
                self?.text = state == .ready ? "" : "블루투스를 켜 주세요"
            }
        }
    }

    func end() { task?.cancel() }
}

// 앱: AdapterBanner(client: BLEClientFactory.make())
// 시험: AdapterBanner(client: FakeClient(session: { id in MyFakeSession(id) }))
// endregion

// region guide:fake-client
/// 구독자에게 값을 나르는 작은 도우미. `replaying:` 을 주면 상태 스트림(구독하자마자 현재 값을 먼저 준다), 안 주면 이벤트 스트림(구독 뒤 값만)
final class FakeStream<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private let replays: Bool
    private var current: Value?
    private var sinks: [UUID: AsyncStream<Value>.Continuation] = [:]
    private var closed = false

    /// 상태 스트림
    init(replaying initial: Value) {
        replays = true
        current = initial
    }

    /// 이벤트 스트림
    init() {
        replays = false
    }

    var value: Value? { lock.withLock { current } }

    func subscribe() -> AsyncStream<Value> {
        AsyncStream { continuation in
            let key = UUID()
            let finishNow = lock.withLock { () -> Bool in
                // 현재 값과 등록을 한 lock 안에서 해야 send 와 순서가 뒤집히지 않는다
                if replays, let current { continuation.yield(current) }
                if closed { return true }
                sinks[key] = continuation
                return false
            }
            if finishNow { continuation.finish(); return }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.sinks.removeValue(forKey: key) } }
        }
    }

    /// 닫힌 뒤에는 무시한다
    func send(_ value: Value) {
        lock.withLock {
            guard !closed else { return }
            if replays { current = value }
            sinks.values.forEach { $0.yield(value) }
        }
    }

    /// finish() 는 onTermination 을 같은 스레드에서 부르므로 lock 밖에서 한다(안에서 하면 교착)
    func finish() {
        let closing = lock.withLock { () -> [AsyncStream<Value>.Continuation] in
            closed = true
            defer { sinks = [:] }
            return Array(sinks.values)
        }
        closing.forEach { $0.finish() }
    }
}

/// 시험용 가짜 client. 라이브러리 계약을 따른다: 상태 스트림은 현재 값 먼저, 이벤트 스트림은 구독 뒤 값만,
/// close() 는 모든 스트림을 끝내고 이후 명령은 CLIENT_CLOSED, register 류는 start() 전에만.
/// 세션은 시험이 BLESession 을 구현한 가짜로 넘긴다(connect 는 시도 시작에서 반환하고 Ready 는 connectionStates 로 알린다)
final class FakeClient: BLEClient, @unchecked Sendable {
    let adapter = FakeStream<AdapterState>(replaying: .unknown)
    let scan = FakeStream<ScanState>(replaying: .idle)
    let results = FakeStream<ScanResult>()
    let eventLog = FakeStream<BLEEvent>()

    private let lock = NSLock()
    private var started = false
    private var closed = false
    private let makeSession: @Sendable (PeripheralID) -> any BLESession

    init(session makeSession: @escaping @Sendable (PeripheralID) -> any BLESession) {
        self.makeSession = makeSession
    }

    var adapterStates: AsyncStream<AdapterState> { adapter.subscribe() }
    var scanStates: AsyncStream<ScanState> { scan.subscribe() }
    var scanResults: AsyncStream<ScanResult> { results.subscribe() }
    var events: AsyncStream<BLEEvent> { eventLog.subscribe() }

    func register(_ peripheralID: PeripheralID, options: ConnectOptions, subscribe: [CharacteristicRef]) {
        precondition(!lock.withLock { started }, "register 는 start() 전에만")
    }

    func registerScan(_ request: ScanRequest) {
        precondition(!lock.withLock { started }, "registerScan 은 start() 전에만")
    }

    func onNotification(queue: DispatchQueue, _ handler: @escaping @Sendable (PeripheralID, CharacteristicRef, Data) -> Void) {
        precondition(!lock.withLock { started }, "onNotification 은 start() 전에만")
    }

    /// 라이브러리처럼 닫힌 뒤에는 아무것도 하지 않는다
    func start() {
        guard lock.withLock({ () -> Bool in
            guard !closed else { return false }
            started = true
            return true
        }) else { return }
        adapter.send(.ready)
    }

    /// 실제는 어댑터가 unknown 이면 최대 2초 판정을 기다린다. 가짜는 ready 가 아니면 바로 거절한다
    func startScan(request: ScanRequest) async throws {
        try throwIfClosed()
        guard adapter.value == .ready else {
            throw BLEError(failure: BLEFailure(code: .adapterUnavailable, message: "fake: adapter not ready"))
        }
        scan.send(.scanning)
    }

    func stopScan() async {
        scan.send(.idle)
    }

    /// 실제처럼 닫힌 뒤에만 던진다. 어떤 ID 에도 세션을 준다
    func session(for peripheralID: PeripheralID) throws -> any BLESession {
        try throwIfClosed()
        return makeSession(peripheralID)
    }

    func connect(_ peripheralID: PeripheralID, options: ConnectOptions) async throws -> any BLESession {
        let session = try session(for: peripheralID)
        try await session.connect(options: options)
        return session
    }

    func snapshot() async -> ClientSnapshot {
        let scanning = if case .scanning = scan.value { true } else { false }
        return ClientSnapshot(adapter: adapter.value ?? .unknown, scanning: scanning, sessions: [])
    }

    func close() {
        lock.withLock { closed = true }
        [adapter.finish, scan.finish, results.finish, eventLog.finish].forEach { $0() }
    }

    private func throwIfClosed() throws {
        if lock.withLock({ closed }) {
            throw BLEError(failure: BLEFailure(code: .clientClosed, message: "fake: closed"))
        }
    }
}
// endregion
