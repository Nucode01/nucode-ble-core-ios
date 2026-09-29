import Foundation

/// 라이브러리 내부의 기한·대기용 시계. 시험은 배율을 주입해 시간을 늘이거나 줄인다.
/// 계약 러너의 `ContractClock`, 가짜 기기의 지연과 같은 배율을 쓴다.
package protocol BLEClock: Sendable {
    /// 이 시계가 만들어진 뒤 흐른 시간(밀리초, 배율을 뺀 계약 시간)
    func nowMilliseconds() -> Int
    /// 계약 시간 `milliseconds` 만큼 기다린다. 호출자가 취소되면 `CancellationError`
    func sleep(milliseconds: Int) async throws
}

/// 실제 시간에 `scale` 을 곱해 기다리는 시계. `scale` 1 은 실제 시간, 0.5 는 두 배 빠르다.
package struct ScaledClock: BLEClock {
    package static let realtime = ScaledClock(scale: 1)

    package let scale: Double
    private let origin = ContinuousClock.now

    package init(scale: Double = 1) {
        precondition(scale > 0, "scale must be positive")
        self.scale = scale
    }

    package func nowMilliseconds() -> Int {
        let elapsed = ContinuousClock.now - origin
        let real = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return Int(real / scale)
    }

    package func sleep(milliseconds: Int) async throws {
        let nanoseconds = Int64(Double(max(0, milliseconds)) * scale * 1_000_000)
        try await Task.sleep(for: .nanoseconds(nanoseconds))
    }
}
