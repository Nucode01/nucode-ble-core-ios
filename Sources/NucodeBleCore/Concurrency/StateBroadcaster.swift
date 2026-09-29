/// 구독하면 현재 값을 먼저 주는 브로드캐스터(Kotlin `StateFlow` 대응, docs/v1/ios-design.md §4).
///
/// 값은 구독자마다 버퍼에 쌓여 전이 순서를 잃지 않는다. `close` 뒤에는 마지막 값이 남고 새 값은 받지 않는다.
@BLECoreActor
package final class StateBroadcaster<Value: Sendable> {
    private(set) package var value: Value
    private(set) package var isClosed = false
    private var subscribers: [UInt64: AsyncStream<Value>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0

    package init(_ initial: Value) {
        value = initial
    }

    /// 현재 값을 첫 원소로 하는 스트림. 등록은 동기라 이 호출 뒤의 `send` 는 반드시 받는다.
    /// 이미 닫혔으면 마지막 값 하나를 주고 끝난다.
    package func subscribe() -> AsyncStream<Value> {
        let (stream, continuation) = AsyncStream.makeStream(of: Value.self, bufferingPolicy: .unbounded)
        continuation.yield(value)
        if isClosed {
            continuation.finish()
            return stream
        }
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { _ in
            Task { @BLECoreActor in self.subscribers.removeValue(forKey: id) }
        }
        return stream
    }

    /// 새 값을 저장하고 모든 구독자에게 같은 순서로 보낸다. 닫힌 뒤에는 무시한다.
    package func send(_ newValue: Value) {
        guard !isClosed else { return }
        value = newValue
        for id in subscribers.keys.sorted() {
            subscribers[id]?.yield(newValue)
        }
    }

    /// 구독자를 모두 끝낸다. 마지막 값은 `value` 와 이후 구독에 남는다.
    package func close() {
        guard !isClosed else { return }
        isClosed = true
        let closing = subscribers
        subscribers.removeAll()
        for continuation in closing.values { continuation.finish() }
    }
}
