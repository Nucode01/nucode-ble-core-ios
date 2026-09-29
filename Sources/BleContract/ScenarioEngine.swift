import Foundation

/// 엔진이 쓰는 시간. 시험은 줄인 시간으로 돌려 빨리 끝낸다
public struct ContractClock: Sendable {
    public let sleep: @Sendable (_ milliseconds: Int) async throws -> Void

    public init(sleep: @escaping @Sendable (_ milliseconds: Int) async throws -> Void) {
        self.sleep = sleep
    }

    public static let continuous = ContractClock { ms in
        try await Task.sleep(for: .milliseconds(ms))
    }

    /// 시나리오의 1ms 를 실제 `factor`ms 로 잔다
    public static func scaled(_ factor: Double) -> ContractClock {
        ContractClock { ms in
            try await Task.sleep(for: .nanoseconds(Int(Double(ms) * factor * 1_000_000)))
        }
    }
}

/// 공개 API 호출 하나의 결과. `result` 레인에 `ok` · `fail <코드>` · `fail EXCEPTION:<타입>`으로 남는다
public enum CallOutcome: Sendable, Equatable {
    case ok
    /// `ok` 뒤에 붙는 값이 있는 성공(`snapshot ok adapter=…`)
    case okWith(String)
    case failed(code: String)
    case exception(typeName: String)

    public var rendered: String {
        switch self {
        case .ok: "ok"
        case .okWith(let detail): "ok \(detail)"
        case .failed(let code): "fail \(code)"
        case .exception(let typeName): "fail EXCEPTION:\(typeName)"
        }
    }
}

/// 백엔드가 공개 관찰을 밀어 넣는 입구. 어느 스레드에서 불러도 된다. 기록이 닫힌 뒤의 관찰은 버린다
public struct ScenarioObserver: Sendable {
    let recorder: Recorder

    /// README 의 state 모양 그대로(`Recovering(LINK_FAILED)`). 초기 상태는 넣지 않는다
    public func state(_ entry: String) {
        recorder.update { $0.log.append(entry, to: .state) }
    }

    /// 앱에 전달된 알림 하나
    public func notification(_ symbol: String) {
        recorder.update { $0.log.append(symbol, to: .notify) }
    }

    /// 활성 구독 집합이 바뀔 때마다. 첫 값(빈 집합)도 넣는다
    public func activeSubscriptions(_ symbols: some Sequence<String>) {
        let entry = ContractLog.renderActive(symbols)
        recorder.update { $0.log.append(entry, to: .active) }
    }

    // 아래 확장 레인은 시나리오의 `expect`에 그 레인이 있을 때만 남는다. 없으면 버린다

    /// `adapter` 레인. 첫 값(`Ready`)도 넣는다
    public func adapter(_ value: AdapterValue) {
        recorder.update(lane: .adapter) { $0.log.append(value.rawValue, to: .adapter) }
    }

    /// `scan` 레인. `Idle` · `Scanning` · `Idle(Failed:<코드>)`. 첫 값(`Idle`)도 넣는다
    public func scan(_ entry: String) {
        recorder.update(lane: .scan) { $0.log.append(entry, to: .scan) }
    }

    /// `services` 레인. 기기 정의에 있는 characteristic 의 기호 이름 집합. 첫 값(빈 집합)도 넣는다
    public func services(_ symbols: some Sequence<String>) {
        let entry = ContractLog.renderActive(symbols)
        recorder.update(lane: .services) { $0.log.append(entry, to: .services) }
    }

    /// 대상 기기의 스캔 결과 하나. 열린 창(`startScan` 직전부터)의 첫 결과만 `found` 레인에 남는다.
    /// 다른 기기의 결과는 넣지 않는다
    public func scanResultForTarget() {
        recorder.update(lane: .found) { s in
            guard s.foundWindowOpen else { return }
            s.foundWindowOpen = false
            s.log.append(s.targetName, to: .found)
        }
    }
}

/// `snapshot` 호출이 돌려주는 클라이언트 관찰
public struct ClientSnapshot: Sendable, Equatable {
    public struct Session: Sendable, Equatable {
        /// 러너가 연결에 쓰는 기기인가. 아니면 `other`로 남는다
        public let isTarget: Bool
        /// `state` 레인과 같은 모양. 초기 상태는 `Disconnected(Initial)`
        public let state: String
        public let subscriptions: [String]

        public init(isTarget: Bool, state: String, subscriptions: [String]) {
            self.isTarget = isTarget
            self.state = state
            self.subscriptions = subscriptions
        }
    }

    public let adapter: AdapterValue
    public let scanning: Bool
    public let sessions: [Session]

    public init(adapter: AdapterValue, scanning: Bool, sessions: [Session]) {
        self.adapter = adapter
        self.scanning = scanning
        self.sessions = sessions
    }

    /// `adapter=Ready scanning=false sessions=[probe:Ready:{probe.value};…]`. 세션은 글자순
    public func rendered(targetName: String) -> String {
        let items = sessions.map {
            "\($0.isTarget ? targetName : "other"):\($0.state):\(ContractLog.renderActive($0.subscriptions))"
        }.sorted()
        return "adapter=\(adapter.rawValue) scanning=\(scanning) sessions=[\(items.joined(separator: ";"))]"
    }
}

/// 4단계에서 실제 iOS 라이브러리(sim: 가짜 포트, device: 실기기)로 구현한다.
/// 단계 순서와 기다림은 엔진이 쥐고, 백엔드는 공개 API 호출과 관찰 전달만 한다
public protocol ScenarioBackend: Sendable {
    /// 첫 단계 전에 한 번. 관찰 원천을 observer 로 잇는다
    func attach(_ observer: ScenarioObserver) async

    /// 공개 실패 타입은 `.failed(code:)`로 돌려준다. 그 밖의 오류는 던지면 `EXCEPTION:<타입>`으로 남는다
    func connect(autoReconnect: Bool) async throws -> CallOutcome
    func disconnect() async throws -> CallOutcome
    func read(_ char: Characteristic) async throws -> CallOutcome
    func write(_ char: Characteristic, bytes: [UInt8], withResponse: Bool, chunking: WriteChunking) async throws -> CallOutcome
    func subscribe(_ char: Characteristic) async throws -> CallOutcome
    func unsubscribe(_ char: Characteristic) async throws -> CallOutcome
    /// 스캔 시작. 결과를 observer 의 `scanResultForTarget()`으로 알린다
    func startScan(filter: ScanFilter) async throws -> CallOutcome
    func stopScan() async throws -> CallOutcome
    func snapshot() async throws -> ClientSnapshot
    /// 클라이언트를 닫는다. 이후 호출은 실패해야 하고, 관찰은 계속 이어진다
    func close() async throws -> CallOutcome

    /// 기기 사건을 일으킨다. 던지면 러너 오류다. `rxCheck`는 `rxCheck()`가 맡으므로 여기 오지 않는다
    func performDeviceEvent(_ event: DeviceEvent) async throws

    /// `probe.control`을 읽어 ASCII `<바이트 수> <ok|bad>`를 돌려준다. 던지면 러너 오류다
    func rxCheck() async throws -> String

    /// sim 전용. 가짜 플랫폼의 어댑터를 바꾼다(실제 플랫폼이 앱에 알리는 경로와 같게). 기기 백엔드는 던진다
    func setAdapter(_ value: AdapterValue) async throws

    /// 기록이 닫힌 뒤의 정리(연결 해제, 클라이언트 닫기). 기록하지 않는다.
    /// 이미 닫힌 클라이언트에서도 실패하지 않아야 한다
    func tearDown() async
}

public struct ScenarioReport: Sendable, Equatable {
    public let scenarioId: String
    public let log: ContractLog
    public let verdict: Verdict

    public func lines(platform: String = "ios") -> [String] {
        log.lines(platform: platform, scenarioId: scenarioId)
            + [ContractLog.verdictLine(verdict, platform: platform, scenarioId: scenarioId)]
    }
}

public struct ScenarioEngine<Backend: ScenarioBackend>: Sendable {
    /// 마지막 단계 뒤에 뒤늦은 기록을 받는 시간
    public static var tailMs: Int { 500 }

    public let backend: Backend
    public let clock: ContractClock

    public init(backend: Backend, clock: ContractClock = .continuous) {
        self.backend = backend
        self.clock = clock
    }

    public func run(_ scenario: Scenario) async -> ScenarioReport {
        let recorder = Recorder(enabled: Set(scenario.expect.keys), targetName: scenario.peripheral.name)
        await backend.attach(ScenarioObserver(recorder: recorder))

        let calls = AsyncCalls()
        var failure: String?
        for (index, step) in scenario.steps.enumerated() {
            if let reason = await execute(step, recorder: recorder, calls: calls, target: scenario.peripheral.name) {
                failure = "step[\(index)] \(Self.describe(step)): \(reason)"
                break
            }
            // async 호출의 시간 초과는 다른 단계 도중에 나므로 단계마다 확인한다
            if let error = recorder.snapshot.runnerError {
                failure = error
                break
            }
        }
        // 실패하면 남은 단계와 꼬리 기록을 건너뛴다
        if failure == nil {
            try? await clock.sleep(Self.tailMs)
        }
        let closed = recorder.close()
        await backend.tearDown()

        let verdict: Verdict = if let reason = failure ?? closed.runnerError {
            .fail(reason: reason)
        } else {
            closed.log.judge(scenario.expect)
        }
        return ScenarioReport(scenarioId: scenario.id, log: closed.log, verdict: verdict)
    }

    /// 실패 이유를 돌려준다. 성공이면 nil
    private func execute(_ step: Step, recorder: Recorder, calls: AsyncCalls, target: String) async -> String? {
        switch step {
        case .call(let call):
            // 대상 기기의 첫 스캔 결과만 남기려고 startScan 을 부르기 직전에 창을 연다
            if case .startScan = call.action {
                recorder.update { $0.foundWindowOpen = true }
            }
            if let name = call.asyncName {
                let task = Task {
                    let entry = await withTimeout(call.timeoutMs, clock) { await perform(call.action, target: target) }
                    recorder.update { s in
                        // 결과 줄은 먼저 끝난 쪽(반환 또는 cancel 단계) 하나만 남긴다
                        guard s.claimed.insert(name).inserted else { return }
                        if let entry {
                            s.log.append(entry, to: .result)
                            s.completed.insert(name)
                        } else if s.runnerError == nil {
                            s.runnerError = "async call \(name) (\(call.action.label)): timed out after \(call.timeoutMs)ms"
                        }
                    }
                }
                calls.add(name, label: call.action.label, task: task)
                return nil
            }
            guard let entry = await withTimeout(call.timeoutMs, clock, { await perform(call.action, target: target) }) else {
                return "timed out after \(call.timeoutMs)ms"
            }
            recorder.update { $0.log.append(entry, to: .result) }
            return nil

        case .wait(let wait):
            let condition: @Sendable (Recorder.Snapshot) -> Bool = switch wait.condition {
            case .state(let pattern):
                { s in s.log[.state].last.map { ContractMatcher.matchesEntry(pattern: pattern, entry: $0) } ?? false }
            case .notify(let count):
                { s in s.log[.notify].count >= count }
            case .result(let name):
                { s in s.completed.contains(name) }
            case .value(let lane, let pattern):
                { s in s.log[lane].last.map { ContractMatcher.matchesEntry(pattern: pattern, entry: $0) } ?? false }
            case .found(let count):
                { s in s.log[.found].count >= count }
            }
            // 러너 오류가 나면 조건을 더 기다리지 않는다
            let woke: Void? = await withTimeout(wait.timeoutMs, clock) {
                await recorder.wait { condition($0) || $0.runnerError != nil }
            }
            // 러너 오류는 이 단계의 실패가 아니라서 run 이 그대로 보고한다
            if recorder.snapshot.runnerError != nil { return nil }
            return woke == nil ? "timed out after \(wait.timeoutMs)ms" : nil

        case .device(let event):
            let last = recorder.snapshot.log[.state].last
            guard last == "Ready" else {
                return "device events need Ready, last state is \(last ?? "none")"
            }
            let backend = self.backend
            let outcome = await withTimeout(Scenario.defaultTimeoutMs, clock) { () async -> String? in
                do {
                    if case .rxCheck = event {
                        let reply = try await backend.rxCheck().trimmingCharacters(in: .whitespacesAndNewlines)
                        guard Self.isRxReply(reply) else { return "rxCheck reply is not \"<bytes> <ok|bad>\": \"\(reply)\"" }
                        recorder.update(lane: .peer) { $0.log.append("rx \(reply)", to: .peer) }
                    } else {
                        try await backend.performDeviceEvent(event)
                    }
                    return nil
                } catch {
                    return "failed: \(error)"
                }
            }
            guard let outcome else { return "timed out after \(Scenario.defaultTimeoutMs)ms" }
            return outcome

        case .sleep(let ms):
            try? await clock.sleep(ms)
            return nil

        case .cancel(let name):
            guard let call = calls.get(name) else { return "no async call named \(name)" }
            // 호출자(러너의 Task)만 취소한다. 라이브러리가 작업을 어떻게 하는지는 레인이 판정한다
            var claimed = false
            recorder.update { s in
                guard s.claimed.insert(name).inserted else { return }
                s.log.append("\(call.label) cancelled", to: .result)
                s.completed.insert(name)
                claimed = true
            }
            if claimed { call.task.cancel() }
            return nil

        case .adapter(let value):
            let backend = self.backend
            let outcome = await withTimeout(Scenario.defaultTimeoutMs, clock) { () async -> String? in
                do {
                    try await backend.setAdapter(value)
                    return nil
                } catch {
                    return "failed: \(error)"
                }
            }
            guard let outcome else { return "timed out after \(Scenario.defaultTimeoutMs)ms" }
            return outcome
        }
    }

    /// `<바이트 수> <ok|bad>`
    public static func isRxReply(_ reply: String) -> Bool {
        let parts = reply.split(separator: " ", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[0].allSatisfy { $0 >= "0" && $0 <= "9" } && (parts[1] == "ok" || parts[1] == "bad")
    }

    /// `result` 레인 항목 한 줄
    private func perform(_ action: CallAction, target: String) async -> String {
        let outcome: CallOutcome
        do {
            outcome = try await invoke(action, target: target)
        } catch {
            outcome = .exception(typeName: String(describing: type(of: error)))
        }
        return "\(action.label) \(outcome.rendered)"
    }

    private func invoke(_ action: CallAction, target: String) async throws -> CallOutcome {
        switch action {
        case .connect(let autoReconnect): try await backend.connect(autoReconnect: autoReconnect)
        case .disconnect: try await backend.disconnect()
        case .read(let c): try await backend.read(c)
        case .write(let c, let bytes, let withResponse, let chunking):
            try await backend.write(c, bytes: bytes, withResponse: withResponse, chunking: chunking)
        case .subscribe(let c): try await backend.subscribe(c)
        case .unsubscribe(let c): try await backend.unsubscribe(c)
        case .startScan(let filter): try await backend.startScan(filter: filter)
        case .stopScan: try await backend.stopScan()
        case .snapshot: .okWith(try await backend.snapshot().rendered(targetName: target))
        case .close: try await backend.close()
        }
    }

    static func describe(_ step: Step) -> String {
        switch step {
        case .call(let call): "call \(call.action.label)" + (call.asyncName.map { " async \($0)" } ?? "")
        case .wait(let wait):
            switch wait.condition {
            case .state(let pattern): "await state \(pattern)"
            case .notify(let count): "await notify \(count)"
            case .result(let name): "await result \(name)"
            case .value(let lane, let pattern): "await \(lane.rawValue) \(pattern)"
            case .found(let count): "await found \(count)"
            }
        case .adapter(let value): "adapter \(value.rawValue)"
        case .device(let event): "device \(event.name)"
        case .sleep(let ms): "sleep \(ms)"
        case .cancel(let name): "cancel \(name)"
        }
    }
}

/// 기록과 기다림. 백엔드 스레드와 엔진 사이에서 공유되므로 lock 으로 지킨다
final class Recorder: @unchecked Sendable {
    struct Snapshot: Sendable {
        var log = ContractLog()
        var completed: Set<String> = []
        /// 결과 줄을 남긴 async 이름(반환 또는 cancel)
        var claimed: Set<String> = []
        var runnerError: String?
        /// `startScan` 직전에 열리고 대상 기기의 첫 결과에서 닫힌다
        var foundWindowOpen = false
        var targetName = ""
    }

    private struct Waiter {
        let predicate: @Sendable (Snapshot) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private let enabled: Set<Lane>
    private var closed = false
    private var waiters: [Int: Waiter] = [:]
    private var cancelled: Set<Int> = []
    private var nextId = 0

    init(enabled: Set<Lane>, targetName: String) {
        self.enabled = enabled
        state.targetName = targetName
    }

    var snapshot: Snapshot {
        locked { state }
    }

    /// 확장 레인은 `expect`에 있을 때만 기록한다
    func update(lane: Lane, _ body: (inout Snapshot) -> Void) {
        guard !lane.isExtension || enabled.contains(lane) else { return }
        update(body)
    }

    func update(_ body: (inout Snapshot) -> Void) {
        let ready: [CheckedContinuation<Void, Never>] = locked {
            guard !closed else { return [] }
            body(&state)
            let hits = waiters.filter { $0.value.predicate(state) }
            for id in hits.keys { waiters[id] = nil }
            return hits.values.map(\.continuation)
        }
        ready.forEach { $0.resume() }
    }

    /// 조건이 참이 되거나, 기록이 닫히거나, 취소될 때까지
    func wait(until predicate: @escaping @Sendable (Snapshot) -> Bool) async {
        let id = locked {
            nextId += 1
            return nextId
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = locked {
                    if closed || cancelled.remove(id) != nil || predicate(state) { return true }
                    waiters[id] = Waiter(predicate: predicate, continuation: continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = locked {
                let w = waiters.removeValue(forKey: id)
                // 등록 전에 취소가 먼저 오면 등록 쪽이 보고 바로 끝낸다
                if w == nil { cancelled.insert(id) }
                return w
            }
            waiter?.continuation.resume()
        }
    }

    /// 기록을 닫는다. 이후의 관찰은 버린다
    func close() -> Snapshot {
        let (snap, pending): (Snapshot, [Waiter]) = locked {
            closed = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return (state, pending)
        }
        pending.forEach { $0.continuation.resume() }
        return snap
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

/// async 호출의 이름·결과 줄 앞부분·Task. cancel 단계가 찾는다
final class AsyncCalls: @unchecked Sendable {
    struct Call {
        let label: String
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var calls: [String: Call] = [:]

    func add(_ name: String, label: String, task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        calls[name] = Call(label: label, task: task)
    }

    func get(_ name: String) -> Call? {
        lock.lock()
        defer { lock.unlock() }
        return calls[name]
    }
}

/// 먼저 도착한 값 하나만 받는 자리
private final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var done = false
    private var continuation: CheckedContinuation<T, Never>?

    func finish(_ v: T) {
        lock.lock()
        guard !done else {
            lock.unlock()
            return
        }
        done = true
        let c = continuation
        continuation = nil
        if c == nil { value = v }
        lock.unlock()
        c?.resume(returning: v)
    }

    func wait() async -> T {
        await withCheckedContinuation { c in
            lock.lock()
            if done, let value {
                lock.unlock()
                c.resume(returning: value)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

/// `op`가 `ms` 안에 끝나면 그 값, 아니면 nil. 끝나지 않는 op 를 기다리며 멈추지 않도록
/// task group 대신 두 Task 를 경주시키고 진 쪽은 취소만 한다
func withTimeout<T: Sendable>(
    _ ms: Int,
    _ clock: ContractClock,
    _ op: @escaping @Sendable () async -> T
) async -> T? {
    let gate = Gate<T?>()
    let work = Task { gate.finish(await op()) }
    let timer = Task {
        do {
            try await clock.sleep(ms)
            gate.finish(nil)
        } catch {}
    }
    // 부른 Task 가 취소되면(cancel 단계) op 도 취소한다. 두 Task 는 구조화되지 않아 취소가 저절로 넘어가지 않는다
    let result = await withTaskCancellationHandler {
        await gate.wait()
    } onCancel: {
        work.cancel()
        timer.cancel()
        gate.finish(nil)
    }
    work.cancel()
    timer.cancel()
    return result
}
