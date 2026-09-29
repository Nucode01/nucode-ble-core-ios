import Dispatch
import NucodeBleCore

/// core 큐의 다음 차례에 `body` 를 실행한다. 순서가 FIFO 로 보장된다.
@BLECoreActor
func fakeEmit<Owner: AnyObject & Sendable>(_ owner: Owner, _ body: @escaping @BLECoreActor (Owner) -> Void) {
    bleCoreQueue.async { [weak owner] in
        BLECoreActor.assumeIsolated {
            if let owner { body(owner) }
        }
    }
}

/// 시계로 `milliseconds` 를 기다린 뒤 core 큐에서 `body` 를 실행한다. 그 사이 `owner` 가 없어졌으면 아무것도 하지 않는다.
@BLECoreActor
func fakeAfter<Owner: AnyObject & Sendable>(
    _ owner: Owner,
    clock: any BLEClock,
    milliseconds: Int,
    _ body: @escaping @BLECoreActor (Owner) -> Void
) {
    Task { @BLECoreActor [weak owner] in
        try? await clock.sleep(milliseconds: milliseconds)
        if let owner { body(owner) }
    }
}
