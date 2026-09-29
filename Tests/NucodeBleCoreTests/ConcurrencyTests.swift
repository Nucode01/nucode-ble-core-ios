import XCTest
@testable import NucodeBleCore

private struct Boom: Error, Equatable {}

final class ConcurrencyTests: XCTestCase {
    // MARK: Waiter

    @BLECoreActor
    func testWaiterResumesOnceWhenResolvedTwice() async throws {
        let waiter = Waiter<Int>()
        let task = Task { @BLECoreActor in try await waiter.value() }
        await Task.yield()
        XCTAssertTrue(waiter.resolve(.success(1)))
        XCTAssertFalse(waiter.resolve(.success(2)))
        XCTAssertFalse(waiter.resolve(.failure(Boom())))
        let first = try await task.value
        let later = try await waiter.value()
        XCTAssertEqual(first, 1)
        XCTAssertEqual(later, 1)
    }

    @BLECoreActor
    func testWaiterResolvedBeforeWaitReturnsImmediately() async {
        let waiter = Waiter<String>()
        waiter.resolve(.failure(Boom()))
        do {
            _ = try await waiter.value()
            XCTFail("실패가 나와야 한다")
        } catch {
            XCTAssertEqual(error as? Boom, Boom())
        }
    }

    @BLECoreActor
    func testCallerCancellationDoesNotChangeWaiterResult() async throws {
        let waiter = Waiter<Int>()
        let cancelled = Task { @BLECoreActor in try await waiter.value() }
        let survivor = Task { @BLECoreActor in try await waiter.value() }
        await Task.yield()
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            XCTFail("취소된 호출자는 CancellationError 를 받아야 한다")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(waiter.isResolved)
        waiter.resolve(.success(7))
        let survived = try await survivor.value
        let after = try await waiter.value()
        XCTAssertEqual(survived, 7)
        XCTAssertEqual(after, 7)
    }

    @BLECoreActor
    func testAlreadyCancelledCallerDoesNotResolveWaiter() async {
        let waiter = Waiter<Int>()
        let task = Task { @BLECoreActor () async throws -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try await waiter.value()
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("CancellationError 여야 한다")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(waiter.isResolved)
    }

    // MARK: StateBroadcaster

    @BLECoreActor
    func testLateSubscriberGetsCurrentValueFirst() async {
        let state = StateBroadcaster(0)
        state.send(1)
        state.send(2)
        var iterator = state.subscribe().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, 2)
        state.send(3)
        let second = await iterator.next()
        XCTAssertEqual(second, 3)
    }

    @BLECoreActor
    func testTwoSubscribersReceiveSameOrder() async {
        let state = StateBroadcaster(0)
        let a = state.subscribe()
        let b = state.subscribe()
        for value in 1...5 { state.send(value) }
        state.close()
        var seenA: [Int] = []
        var seenB: [Int] = []
        for await value in a { seenA.append(value) }
        for await value in b { seenB.append(value) }
        XCTAssertEqual(seenA, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(seenB, seenA)
    }

    @BLECoreActor
    func testCloseKeepsLastValueAndDropsNewOnes() async {
        let state = StateBroadcaster("a")
        state.send("b")
        state.close()
        state.send("c")
        XCTAssertEqual(state.value, "b")
        var seen: [String] = []
        for await value in state.subscribe() { seen.append(value) }
        XCTAssertEqual(seen, ["b"])
    }

    // MARK: EventHub

    @BLECoreActor
    func testEventHubDeliversToEachSubscriberInOrder() async {
        let hub = EventHub<Int>()
        let a = hub.subscribe()
        hub.emit(0)
        let b = hub.subscribe()
        for value in 1...3 { hub.emit(value) }
        hub.close()
        var seenA: [Int] = []
        var seenB: [Int] = []
        for await value in a { seenA.append(value) }
        for await value in b { seenB.append(value) }
        XCTAssertEqual(seenA, [0, 1, 2, 3])
        XCTAssertEqual(seenB, [1, 2, 3])
    }

    @BLECoreActor
    func testEventHubBufferLimitDropsOldest() async {
        let hub = EventHub<Int>()
        let slow = hub.subscribe(bufferLimit: 2)
        for value in 1...5 { hub.emit(value) }
        hub.close()
        var seen: [Int] = []
        for await value in slow { seen.append(value) }
        XCTAssertEqual(seen, [4, 5])
    }

    @BLECoreActor
    func testEventHubSubscribeAfterCloseEndsImmediately() async {
        let hub = EventHub<Int>()
        hub.close()
        var seen: [Int] = []
        for await value in hub.subscribe() { seen.append(value) }
        XCTAssertTrue(seen.isEmpty)
    }
}
