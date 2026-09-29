import Foundation

/// OS 가 연결 요청을 받기 전까지의 시도 하나(어댑터 판정 → 기기 확보 → `central.connect`).
/// `startWaiter` 는 `connect()` 가 반환할 때까지만 쓴다(docs/v1/ios-design.md §6).
/// 시도가 실패하면 연결 상태는 바뀌지 않는다(contract/states.md §4).
@BLECoreActor
package final class ConnectAttempt {
    package let generation: UInt64
    package let options: ConnectOptions
    package let startWaiter = Waiter<Void>()
    /// link deadline 의 절대 시각(계약 시간). autoReconnect 면 없다
    package let linkDeadlineAt: Int?
    package var gate: AdapterGate?
    package var resolver: PeripheralResolver?

    package init(generation: UInt64, options: ConnectOptions, linkDeadlineAt: Int?) {
        self.generation = generation
        self.options = options
        self.linkDeadlineAt = linkDeadlineAt
    }
}
