import Foundation

/// OS 가 연결 요청을 받기 전까지의 시도 하나(어댑터 판정 → 기기 확보 → `central.connect`)가 Runtime 에 남기는 것:
/// 호출자를 기다리게 하는 `startWaiter`, 어댑터 판정 `gate`, 기기 확보 `resolver`. 세대·옵션·기한은 Core 상태가 든다.
/// `startWaiter` 는 `connect()` 가 반환할 때까지만 쓴다(docs/v1/ios-design.md §6).
/// 시도가 실패하면 연결 상태는 바뀌지 않는다(contract/states.md §4).
@BLECoreActor
package final class ConnectAttempt {
    package let generation: UInt64
    package let startWaiter = Waiter<Void>()
    package var gate: AdapterGate?
    package var resolver: PeripheralResolver?

    package init(generation: UInt64) {
        self.generation = generation
    }
}
