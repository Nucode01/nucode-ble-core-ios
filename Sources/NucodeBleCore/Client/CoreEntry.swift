import Dispatch

private let coreQueueKey = DispatchSpecificKey<Bool>()
private let coreQueueMarked: Void = bleCoreQueue.setSpecific(key: coreQueueKey, value: true)

/// nonisolated 공개 API 가 core 안의 동기 상태를 읽고 쓰는 입구.
/// core 큐 위면 바로 실행하고, 밖이면 큐에서 끝날 때까지 기다린다(구독 등록이 동기라 이후 emit 을 놓치지 않는다).
/// `await` 를 쓰지 않으므로 재진입이 생기지 않는다. core 큐 위에서 부르는 경로도 안전하다.
package func runOnCore<T: Sendable>(_ body: @BLECoreActor () -> T) -> T {
    _ = coreQueueMarked
    if DispatchQueue.getSpecific(key: coreQueueKey) == true {
        return BLECoreActor.assumeIsolated(body)
    }
    return bleCoreQueue.sync { BLECoreActor.assumeIsolated(body) }
}
