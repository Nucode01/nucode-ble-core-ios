/// 구독자별 continuation 으로 이벤트를 나르는 브로드캐스터(Kotlin `SharedFlow` + 수집자별 버퍼 대응, docs/v1/ios-design.md §4).
///
/// 구독 전 이벤트는 받지 못한다. 버퍼가 차면 가장 오래된 것부터 버린다(느린 구독자의 유실 허용).
@BLECoreActor
package final class EventHub<Event: Sendable> {
    package static var defaultBufferLimit: Int { 256 }

    private var subscribers: [UInt64: AsyncStream<Event>.Continuation] = [:]
    private var nextSubscriberID: UInt64 = 0
    private(set) package var isClosed = false

    package init() {}

    package var subscriberCount: Int { subscribers.count }

    /// 등록은 동기라 이 호출 뒤의 `emit` 은 반드시 받는다. 닫혔으면 바로 끝나는 스트림.
    package func subscribe(bufferLimit: Int = EventHub.defaultBufferLimit) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Event.self, bufferingPolicy: .bufferingNewest(max(1, bufferLimit))
        )
        guard !isClosed else {
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

    package func emit(_ event: Event) {
        guard !isClosed else { return }
        for id in subscribers.keys.sorted() {
            subscribers[id]?.yield(event)
        }
    }

    package func close() {
        guard !isClosed else { return }
        isClosed = true
        let closing = subscribers
        subscribers.removeAll()
        for continuation in closing.values { continuation.finish() }
    }
}
