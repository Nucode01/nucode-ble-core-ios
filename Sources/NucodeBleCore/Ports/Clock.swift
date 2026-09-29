import Foundation

/// 라이브러리 내부의 기한·대기용 시계. 시험은 배율을 주입해 시간을 늘이거나 줄인다.
/// 계약 러너의 `ContractClock`, 가짜 기기의 지연과 같은 배율을 쓴다.
package protocol BLEClock: Sendable {
    /// 이 시계가 만들어진 뒤 흐른 시간(밀리초, 배율을 뺀 계약 시간)
    func nowMilliseconds() -> Int
    /// 계약 시간 `milliseconds` 만큼 기다린다. 호출자가 취소되면 `CancellationError`
    func sleep(milliseconds: Int) async throws
}
