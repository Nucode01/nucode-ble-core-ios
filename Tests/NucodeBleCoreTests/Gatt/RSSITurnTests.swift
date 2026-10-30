import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// RSSI 차례(contract/states.md §8 RSSI 읽기, CANDIDATE-34): 차례를 플랫폼 결과나 기한 전에 놓지 않는지, 같은 기기 결과 공유, 세션별 무효화.
/// 기한은 `ScaledClock(scale: 0.05)` 라 5000ms 가 실제 250ms 다
@BLECoreActor
final class RSSITurnTests: XCTestCase {
    private let deviceA = PeripheralID(rawValue: "A")
    private let deviceB = PeripheralID(rawValue: "B")
    private let deviceC = PeripheralID(rawValue: "C")
    private let clock = ScaledClock(scale: ClientTestSupport.scale)

    /// 세션 자리(참가자를 가르는 주인)
    private final class Owner {}

    /// 차례가 부른 `start` 를 이름별로 센다
    @BLECoreActor
    private final class Starts {
        var counts: [String: Int] = [:]
        func make(_ name: String) -> @BLECoreActor () -> Void {
            { [self] in counts[name, default: 0] += 1 }
        }
        subscript(_ name: String) -> Int { counts[name, default: 0] }
    }

    /// 호출자 하나의 결과: dBm, 실패 코드, `cancelled`
    @BLECoreActor
    private final class Outcome {
        var value: String?
        var task: Task<Void, Never>?
    }

    private func track(_ waiter: Waiter<Int>) -> Outcome {
        let outcome = Outcome()
        outcome.task = Task { @BLECoreActor in
            do {
                outcome.value = "\(try await waiter.value())"
            } catch let error as BLEError {
                outcome.value = error.failure.code.value
            } catch is CancellationError {
                outcome.value = "cancelled"
            } catch {
                outcome.value = "other"
            }
        }
        return outcome
    }

    private func waitUntil(realMilliseconds limit: Int = 2000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    func testOtherDeviceWaitsForPlatformResult() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner()
        let a = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        let b = track(turn.request(deviceB, owner: s2, clock: clock, start: starts.make("B")))
        XCTAssertEqual(starts["A"], 1)
        XCTAssertEqual(starts["B"], 0, "다른 기기는 차례를 기다린다")
        XCTAssertTrue(turn.didRead(deviceA, .success(-40)))
        XCTAssertEqual(starts["B"], 1)
        let aDone = await waitUntil { a.value != nil }
        XCTAssertTrue(aDone)
        XCTAssertEqual(a.value, "-40")
        XCTAssertNil(b.value)
    }

    func testCancelledCallerKeepsTurnUntilPlatformResult() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner()
        let a = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        _ = track(turn.request(deviceB, owner: s2, clock: clock, start: starts.make("B")))
        a.task?.cancel()
        let cancelled = await waitUntil { a.value != nil }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(a.value, "cancelled")
        await settle()
        XCTAssertEqual(starts["B"], 0, "취소는 호출자만 뗀다. 차례는 A 결과까지 그대로다")
        turn.didRead(deviceA, .success(-40))
        XCTAssertEqual(starts["B"], 1)
    }

    func testInvalidatedCallerKeepsTurnUntilPlatformResult() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner()
        let a = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        _ = track(turn.request(deviceB, owner: s2, clock: clock, start: starts.make("B")))
        turn.invalidate(deviceA, owner: s1, BLEFailure(code: .operationInvalidated, message: "x"))
        let ended = await waitUntil { a.value != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(a.value, "OPERATION_INVALIDATED")
        await settle()
        XCTAssertEqual(starts["B"], 0, "해제가 차례를 일찍 놓지 않는다")
        XCTAssertTrue(turn.didRead(deviceA, .success(-40)))
        XCTAssertEqual(starts["B"], 1)
    }

    func testDeadlineTimesOutAndNextDeadlineCountsFromItsOwnSend() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner()
        let a = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        try? await Task.sleep(for: .milliseconds(150))
        let b = track(turn.request(deviceB, owner: s2, clock: clock, start: starts.make("B")))
        let timedOut = await waitUntil { a.value != nil }
        XCTAssertTrue(timedOut)
        XCTAssertEqual(a.value, "RSSI_READ_TIMEOUT")
        XCTAssertEqual(starts["B"], 1, "기한이 지나면 차례를 놓는다")
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(b.value, "B 의 기한은 B 를 보낸 때부터다(줄에서 기다린 시간은 넣지 않는다)")
        XCTAssertFalse(turn.didRead(deviceA, .success(-40)), "늦은 A 결과는 진행 중인 B 를 끝내지 않는다")
        await settle()
        XCTAssertNil(b.value)
        XCTAssertTrue(turn.didRead(deviceB, .success(-30)))
        let bDone = await waitUntil { b.value != nil }
        XCTAssertTrue(bDone)
        XCTAssertEqual(b.value, "-30")
    }

    func testSameDeviceCallsShareOneRequest() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner()
        let first = turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A1"))
        let again = turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A1"))
        XCTAssertTrue(first === again, "같은 세션의 겹친 호출은 같은 결과를 기다린다")
        let other = track(turn.request(deviceA, owner: s2, clock: clock, start: starts.make("A2")))
        XCTAssertEqual(starts["A1"] + starts["A2"], 1, "플랫폼 요청은 하나다")
        let mine = track(first)
        turn.didRead(deviceA, .success(-50))
        let done = await waitUntil { mine.value != nil && other.value != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(mine.value, "-50")
        XCTAssertEqual(other.value, "-50")
    }

    func testQueuedSameDeviceCallsMergeAndStartOnce() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner(), s3 = Owner()
        _ = turn.request(deviceB, owner: s3, clock: clock, start: starts.make("B"))
        let a1 = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A1")))
        let a2 = track(turn.request(deviceA, owner: s2, clock: clock, start: starts.make("A2")))
        XCTAssertEqual(starts["A1"] + starts["A2"], 0)
        turn.didRead(deviceB, .success(-60))
        XCTAssertEqual(starts["A1"], 1)
        XCTAssertEqual(starts["A2"], 0, "줄에서 합친 요청은 한 번만 보낸다")
        turn.didRead(deviceA, .success(-50))
        let done = await waitUntil { a1.value != nil && a2.value != nil }
        XCTAssertTrue(done)
        XCTAssertEqual([a1.value, a2.value], ["-50", "-50"])
    }

    func testInvalidatedSessionDoesNotRejoinRunningRequest() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner()
        let old = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        turn.invalidate(deviceA, owner: s1, BLEFailure(code: .operationInvalidated, message: "x"))
        let fresh = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        XCTAssertEqual(starts["A"], 1, "새 호출은 옛 링크의 요청에 붙지 않고 줄에 선다")
        turn.didRead(deviceA, .success(-70))
        XCTAssertEqual(starts["A"], 2)
        turn.didRead(deviceA, .success(-50))
        let done = await waitUntil { old.value != nil && fresh.value != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(old.value, "OPERATION_INVALIDATED")
        XCTAssertEqual(fresh.value, "-50")
    }

    func testInvalidatedQueuedRequestLeavesTheLine() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner(), s3 = Owner()
        _ = turn.request(deviceB, owner: s2, clock: clock, start: starts.make("B"))
        let a = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A")))
        turn.invalidate(deviceA, owner: s1, BLEFailure(code: .operationInvalidated, message: "x"))
        let ended = await waitUntil { a.value != nil }
        XCTAssertTrue(ended)
        XCTAssertEqual(a.value, "OPERATION_INVALIDATED")
        turn.didRead(deviceB, .success(-60))
        XCTAssertEqual(starts["A"], 0, "보내지 않은 요청은 줄에서 빠진다")
        _ = turn.request(deviceC, owner: s3, clock: clock, start: starts.make("C"))
        XCTAssertEqual(starts["C"], 1, "차례가 비어 있다")
    }

    func testClosingOneSessionLeavesOtherSessionOnSameDevice() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner()
        let first = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A1")))
        let second = track(turn.request(deviceA, owner: s2, clock: clock, start: starts.make("A2")))
        XCTAssertEqual(starts["A1"] + starts["A2"], 1)
        turn.invalidate(deviceA, owner: s1, BLEFailure(code: .clientClosed, message: "x"))
        let closed = await waitUntil { first.value != nil }
        XCTAssertTrue(closed)
        XCTAssertEqual(first.value, "CLIENT_CLOSED")
        await settle()
        XCTAssertNil(second.value, "다른 세션의 호출은 끝나지 않는다")
        turn.didRead(deviceA, .success(-50))
        let done = await waitUntil { second.value != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(second.value, "-50")
    }

    func testQueuedRequestStartsThroughFirstLiveParticipant() async {
        let turn = RSSITurn()
        let starts = Starts()
        let s1 = Owner(), s2 = Owner(), s3 = Owner()
        _ = turn.request(deviceB, owner: s3, clock: clock, start: starts.make("B"))
        _ = track(turn.request(deviceA, owner: s1, clock: clock, start: starts.make("A1")))
        let second = track(turn.request(deviceA, owner: s2, clock: clock, start: starts.make("A2")))
        turn.invalidate(deviceA, owner: s1, BLEFailure(code: .operationInvalidated, message: "x"))
        turn.didRead(deviceB, .success(-60))
        XCTAssertEqual(starts["A1"], 0, "끝난 참가자의 기기 객체로 보내지 않는다")
        XCTAssertEqual(starts["A2"], 1)
        turn.didRead(deviceA, .success(-50))
        let done = await waitUntil { second.value != nil }
        XCTAssertTrue(done)
        XCTAssertEqual(second.value, "-50")
    }
}
