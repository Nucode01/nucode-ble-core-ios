import Foundation

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
