/// resume 를 정확히 한 번만 보장하는 대기 지점(Kotlin `CompletableDeferred` 대응, docs/v1/ios-design.md §4).
///
/// 결과는 첫 `resolve` 가 정한다. continuation 을 깨우는 곳은 `resolve` 하나뿐이고, 어느 경로(완료·실패·
/// disconnect·timeout)가 먼저 와도 이 함수를 거친다. 대기하던 호출자가 취소되면 그 호출자만 떼어 내고
/// (`CancellationError`) Waiter 의 결과는 바뀌지 않는다.
@BLECoreActor
package final class Waiter<Value: Sendable> {
    private var result: Result<Value, any Error>?
    private var callers: [UInt64: CheckedContinuation<Value, any Error>] = [:]
    private var nextCallerID: UInt64 = 0

    package init() {}

    package var isResolved: Bool { result != nil }

    /// 첫 호출만 결과를 정하고 true 를 돌려준다. 이후 호출은 무시하고 false.
    @discardableResult
    package func resolve(_ outcome: Result<Value, any Error>) -> Bool {
        guard result == nil else { return false }
        result = outcome
        let waiting = callers
        callers.removeAll()
        for id in waiting.keys.sorted() {
            waiting[id]?.resume(with: outcome)
        }
        return true
    }

    /// 결과가 정해질 때까지 기다린다. 진입 계층의 마지막 줄에서만 부른다.
    package func value() async throws -> Value {
        if let result { return try result.get() }
        let id = nextCallerID
        nextCallerID += 1
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    continuation.resume(with: result)
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    callers[id] = continuation
                }
            }
        } onCancel: {
            Task { @BLECoreActor in self.detach(id) }
        }
    }

    /// 호출자 하나만 떼어 낸다. 이미 깨어난 호출자면 아무 일도 없다.
    private func detach(_ id: UInt64) {
        callers.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
