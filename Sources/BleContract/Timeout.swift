import Foundation

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
