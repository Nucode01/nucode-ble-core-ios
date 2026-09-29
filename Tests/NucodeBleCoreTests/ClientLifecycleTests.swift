import BleCoreFakes
import XCTest
@testable import NucodeBleCore

final class ClientLifecycleTests: XCTestCase {
    typealias Support = ClientTestSupport

    @BLECoreActor
    func testStartIsIdempotentAndCreatesManagerOnce() async {
        final class Counter: @unchecked Sendable { var created = 0 }
        let counter = Counter()
        let client = Support.makeClient {
            counter.created += 1
            return Support.makeCentral()
        }
        XCTAssertEqual(counter.created, 0, "생성자는 manager 를 만들지 않는다")
        client.start()
        client.start()
        XCTAssertEqual(counter.created, 1)
        client.close()
    }

    @BLECoreActor
    func testSessionIsBornDisconnectedInitial() async throws {
        let client = Support.makeClient { Support.makeCentral() }
        let id = PeripheralID(rawValue: "device-1")
        let session = try client.session(for: id)
        XCTAssertEqual(session.peripheralID, id)
        var iterator = session.connectionStates.makeAsyncIterator()
        let first = await iterator.next()
        guard case .disconnected(reason: .initial)? = first else {
            return XCTFail("Disconnected(Initial) 이어야 한다: \(String(describing: first))")
        }
        client.close()
    }

    @BLECoreActor
    func testSessionForSameIDIsShared() async throws {
        let client = Support.makeClient { Support.makeCentral() }
        let id = PeripheralID(rawValue: "device-1")
        _ = try client.session(for: id)
        _ = try client.session(for: id)
        XCTAssertEqual(client.runtime.registry.sessions.count, 1)
        client.close()
    }

    @BLECoreActor
    func testSnapshotReportsAdapterScanningAndSessions() async throws {
        let central = Support.makeCentral()
        let client = Support.makeClient { central }
        client.start()
        _ = try client.session(for: PeripheralID(rawValue: "b"))
        _ = try client.session(for: PeripheralID(rawValue: "a"))
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.adapter, .ready)
        XCTAssertFalse(snapshot.scanning)
        XCTAssertEqual(snapshot.sessions.map(\.peripheralID.rawValue), ["a", "b"])
        for session in snapshot.sessions {
            guard case .disconnected(reason: .initial) = session.state else { return XCTFail("Initial 이어야 한다") }
            XCTAssertTrue(session.subscriptions.isEmpty)
        }
        client.close()
    }

    @BLECoreActor
    func testCloseIsIdempotentFreezesSnapshotAndRejectsCommands() async throws {
        let central = Support.makeCentral()
        let client = Support.makeClient { central }
        client.start()
        _ = try client.session(for: PeripheralID(rawValue: "a"))
        var states = client.adapterStates.makeAsyncIterator()
        let ready = await states.next()
        XCTAssertEqual(ready, .ready)

        client.close()
        client.close()

        let frozen = await client.snapshot()
        XCTAssertEqual(frozen.adapter, .ready)
        XCTAssertEqual(frozen.sessions.count, 1)

        // 닫힌 뒤 어댑터가 바뀌어도 스냅숏은 그대로
        central.setAdapter(.poweredOff)
        await Support.sleep(realMilliseconds: 20)
        let after = await client.snapshot()
        XCTAssertEqual(after.adapter, .ready)

        let end = await states.next()
        XCTAssertNil(end, "닫으면 어댑터 흐름이 끝난다")

        let result = await GateProbe(client.runtime).wait()
        XCTAssertEqual(result, "CLIENT_CLOSED")

        do {
            _ = try client.session(for: PeripheralID(rawValue: "b"))
            XCTFail("닫힌 뒤 session(for:) 는 실패해야 한다")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .clientClosed)
        }
    }

    @BLECoreActor
    func testEventsStreamEndsOnClose() async {
        let client = Support.makeClient { Support.makeCentral() }
        var iterator = client.events.makeAsyncIterator()
        client.close()
        let event = await iterator.next()
        XCTAssertNil(event)
    }

    @BLECoreActor
    func testStartAfterCloseDoesNothing() async {
        final class Counter: @unchecked Sendable { var created = 0 }
        let counter = Counter()
        let client = Support.makeClient {
            counter.created += 1
            return Support.makeCentral()
        }
        client.close()
        client.start()
        XCTAssertEqual(counter.created, 0)
    }
}
