import Foundation
import XCTest
@testable import NucodeBleCore

/// ScaledClock 의 나노초 시각(CANDIDATE-36c 스캔 결과 시각의 원천)
final class ScaledClockTests: XCTestCase {
    /// 인스턴스 origin 부터 잰다: 새 시계는 0 근처에서 시작한다
    func testNanosecondsStartAtInstanceOrigin() {
        let clock = ScaledClock(scale: 1)
        XCTAssertLessThan(clock.nowNanoseconds(), 50_000_000)
        XCTAssertGreaterThanOrEqual(clock.nowNanoseconds(), 0)
    }

    /// scale 0.5 는 두 배 빠르다: 실제 경과의 약 2배를 돌려준다
    func testNanosecondsAreRealElapsedDividedByScale() {
        let clock = ScaledClock(scale: 0.5)
        let realStart = ContinuousClock.now
        let start = clock.nowNanoseconds()
        Thread.sleep(forTimeInterval: 0.05)
        let end = clock.nowNanoseconds()
        let real = ContinuousClock.now - realStart
        let realNanos = Double(real.components.seconds) * 1e9 + Double(real.components.attoseconds) / 1e9
        let ratio = Double(end - start) / realNanos
        XCTAssertEqual(ratio, 2, accuracy: 0.1)
    }

    /// 밀리초 시각과 같은 시간을 센다
    func testNanosecondsAgreeWithMilliseconds() {
        let clock = ScaledClock(scale: 0.5)
        Thread.sleep(forTimeInterval: 0.02)
        let nanos = clock.nowNanoseconds()
        let millis = clock.nowMilliseconds()
        let nanosAfter = clock.nowNanoseconds()
        XCTAssertLessThanOrEqual(Int(nanos / 1_000_000), millis)
        XCTAssertLessThanOrEqual(millis, Int(nanosAfter / 1_000_000) + 1)
    }

    /// 1ms 보다 촘촘하다: 연속으로 읽으면 1ms 의 배수가 아닌 값이 나온다
    func testNanosecondsHaveSubMillisecondResolution() {
        let clock = ScaledClock(scale: 1)
        let values = (0..<20).map { _ in clock.nowNanoseconds() }
        XCTAssertTrue(values.contains { $0 % 1_000_000 != 0 })
        XCTAssertEqual(values, values.sorted(), "줄지 않는다")
    }
}
