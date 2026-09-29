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
    case failed(code: String)
    case exception(typeName: String)

    public var rendered: String {
        switch self {
        case .ok: "ok"
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
    func write(_ char: Characteristic, bytes: [UInt8], withResponse: Bool) async throws -> CallOutcome
    func subscribe(_ char: Characteristic) async throws -> CallOutcome
    func unsubscribe(_ char: Characteristic) async throws -> CallOutcome

    /// 기기 사건을 일으킨다. 던지면 러너 오류다
    func performDeviceEvent(_ event: DeviceEvent) async throws

    /// 기록이 닫힌 뒤의 정리(연결 해제, 클라이언트 닫기). 기록하지 않는다
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
        let recorder = Recorder()
        await backend.attach(ScenarioObserver(recorder: recorder))

        var failure: String?
        for (index, step) in scenario.steps.enumerated() {
            if let reason = await execute(step, recorder: recorder) {
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
    private func execute(_ step: Step, recorder: Recorder) async -> String? {
        switch step {
        case .call(let call):
            if let name = call.asyncName {
                Task {
                    let entry = await withTimeout(call.timeoutMs, clock) { await perform(call.action) }
                    recorder.update { s in
                        if let entry {
                            s.log.append(entry, to: .result)
                            s.completed.insert(name)
                        } else if s.runnerError == nil {
                            s.runnerError = "async call \(name) (\(call.action.label)): timed out after \(call.timeoutMs)ms"
                        }
                    }
                }
                return nil
            }
            guard let entry = await withTimeout(call.timeoutMs, clock, { await perform(call.action) }) else {
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
                    try await backend.performDeviceEvent(event)
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
        }
    }

    /// `result` 레인 항목 한 줄
    private func perform(_ action: CallAction) async -> String {
        let outcome: CallOutcome
        do {
            outcome = try await invoke(action)
        } catch {
            outcome = .exception(typeName: String(describing: type(of: error)))
        }
        return "\(action.label) \(outcome.rendered)"
    }

    private func invoke(_ action: CallAction) async throws -> CallOutcome {
        switch action {
        case .connect(let autoReconnect): try await backend.connect(autoReconnect: autoReconnect)
        case .disconnect: try await backend.disconnect()
        case .read(let c): try await backend.read(c)
        case .write(let c, let bytes, let withResponse): try await backend.write(c, bytes: bytes, withResponse: withResponse)
        case .subscribe(let c): try await backend.subscribe(c)
        case .unsubscribe(let c): try await backend.unsubscribe(c)
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
            }
        case .device(let event): "device \(event.name)"
        case .sleep(let ms): "sleep \(ms)"
        }
    }
}

/// 기록과 기다림. 백엔드 스레드와 엔진 사이에서 공유되므로 lock 으로 지킨다
final class Recorder: @unchecked Sendable {
    struct Snapshot: Sendable {
        var log = ContractLog()
        var completed: Set<String> = []
        var runnerError: String?
    }

    private struct Waiter {
        let predicate: @Sendable (Snapshot) -> Bool
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private var closed = false
    private var waiters: [Int: Waiter] = [:]
    private var cancelled: Set<Int> = []
    private var nextId = 0

    var snapshot: Snapshot {
        locked { state }
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
    let result = await gate.wait()
    work.cancel()
    timer.cancel()
    return result
}
