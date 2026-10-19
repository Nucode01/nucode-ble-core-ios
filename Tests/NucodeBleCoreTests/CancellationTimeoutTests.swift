import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// 큐 기한 판정, 호출자 취소, 무효화, close 정리 (contract/states.md §10)
@BLECoreActor
final class CancellationTimeoutTests: XCTestCase {
    /// 시험이 직접 기한을 울리는 시계
    final class ManualClock: BLEClock, @unchecked Sendable {
        private let lock = NSLock()
        private var sleepers: [CheckedContinuation<Void, Never>] = []

        func nowMilliseconds() -> Int { 0 }

        func sleep(milliseconds: Int) async throws {
            await withCheckedContinuation { continuation in
                lock.lock()
                sleepers.append(continuation)
                lock.unlock()
            }
            try Task.checkCancellation()
        }

        func fire() {
            lock.lock()
            let all = sleepers
            sleepers = []
            lock.unlock()
            for sleeper in all { sleeper.resume() }
        }
    }

    private let port = CharacteristicRef(
        service: ServiceRef(uuid: BLEUUID(string: "1234")!, instanceIndex: 0), uuid: BLEUUID(string: "abcd")!, instanceIndex: 0
    )

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "ok"
        } catch let error as BLEError {
            return error.failure.code.value
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return "other"
        }
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testCompletionAlreadyQueuedAtDeadlineWinsOverTimeout() async {
        let clock = ManualClock()
        let queue = OperationQueue(clock: clock, timeoutMilliseconds: 5000)
        var poisoned = 0
        queue.onPoison = { _ in poisoned += 1 }
        let waiter = queue.submit(.read, characteristic: port, start: {})
        await settle()
        clock.fire()
        // 기한 깨움이 큐에 들어간 뒤, 완료 콜백이 판정보다 먼저 큐에 들어와 있다
        Task { @BLECoreActor in _ = queue.didUpdateValue(for: port, value: Data([7]), error: nil) }
        let value = try? await waiter.value()
        XCTAssertEqual(value, Data([7]))
        await settle()
        XCTAssertEqual(poisoned, 0)
    }

    func testDeadlineWithoutCompletionTimesOutAndPoisons() async {
        let clock = ManualClock()
        let queue = OperationQueue(clock: clock, timeoutMilliseconds: 5000)
        var poisoned: [String] = []
        queue.onPoison = { poisoned.append($0.code.value) }
        var started = 0
        let waiter = queue.submit(.read, characteristic: port, start: { started += 1 })
        let waiting = queue.submit(.read, characteristic: port, start: { started += 1 })
        await settle()
        clock.fire()
        let result = await code { _ = try await waiter.value() }
        await settle()
        // 기한 초과는 대기 작업을 시작하지 않고 끝낸다. 시작했다면 아래 await 가 기한 없이 멈추므로 먼저 본다
        guard started == 1 else { return XCTFail("started \(started)") }
        let waitingResult = await code { _ = try await waiting.value() }
        XCTAssertEqual(result, "OPERATION_TIMEOUT")
        XCTAssertEqual(waitingResult, "OPERATION_INVALIDATED")
        XCTAssertEqual(poisoned, ["OPERATION_TIMEOUT"])
        // 늦은 콜백은 어떤 요청도 끝내지 못한다
        XCTAssertFalse(queue.didUpdateValue(for: port, value: Data([1]), error: nil))
    }

    func testCallerCancellationDoesNotEndQueuedOperation() async {
        let queue = OperationQueue(clock: ManualClock(), timeoutMilliseconds: 5000)
        let waiter = queue.submit(.read, characteristic: port, start: {})
        let caller = Task { @BLECoreActor in await self.code { _ = try await waiter.value() } }
        await settle()
        caller.cancel()
        let callerResult = await caller.value
        XCTAssertEqual(callerResult, "cancelled")
        XCTAssertFalse(queue.isIdle)
        _ = queue.didUpdateValue(for: port, value: Data([1]), error: nil)
        let value = try? await waiter.value()
        XCTAssertEqual(value, Data([1]))
    }

    func testInvalidateEndsWaitingOperationAsInvalidated() async {
        let queue = OperationQueue(clock: ManualClock(), timeoutMilliseconds: 5000)
        let first = queue.submit(.read, characteristic: port, start: {})
        let second = queue.submit(.setNotify(enabled: true), characteristic: port, start: {})
        queue.invalidate(GattFailure.invalidated("disconnect"))
        let firstResult = await code { _ = try await first.value() }
        let secondResult = await code { _ = try await second.value() }
        XCTAssertEqual(firstResult, "OPERATION_INVALIDATED")
        XCTAssertEqual(secondResult, "OPERATION_INVALIDATED")
        XCTAssertTrue(queue.isIdle)
    }

    /// 기한 판정이 쓰는 실제 시계(ScaledClock)는 배율만큼 줄여 잔다
    func testScaledClockScalesSleep() async throws {
        let clock = ScaledClock(scale: 0.1)
        let start = ContinuousClock.now
        try await clock.sleep(milliseconds: 500)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(300))
        XCTAssertGreaterThanOrEqual(clock.nowMilliseconds(), 40)
    }

    func testCloseIsIdempotentAndEndsInitialSessionUntouched() async throws {
        let central = ClientTestSupport.makeCentral()
        let client = ClientTestSupport.makeClient { central }
        client.start()
        let session = client.runtime.registry.session(for: FakeDeviceSpec.defaultID)
        client.close()
        client.close()
        await client.stopScan()
        await client.stopScan()
        guard case .disconnected(reason: .initial) = session.state.value else { return XCTFail("\(session.state.value)") }
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.sessions.count, 1)
    }
}
