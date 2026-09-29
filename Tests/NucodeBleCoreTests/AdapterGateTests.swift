import BleCoreFakes
import XCTest
@testable import NucodeBleCore

/// 명령용 어댑터 판정(contract/states.md §6). iOS 전용 권한 팝업 예외는 시나리오가 없어 여기서 판정한다.
final class AdapterGateTests: XCTestCase {
    typealias Support = ClientTestSupport

    // MARK: 상태 옮김

    func testMapsStateAndAuthorization() {
        let cases: [(CentralPortState, PortAuthorization, AdapterState)] = [
            (.unknown, .notDetermined, .unknown),
            (.unknown, .allowedAlways, .unknown),
            (.resetting, .allowedAlways, .resetting),
            (.unsupported, .allowedAlways, .unsupported),
            (.unauthorized, .notDetermined, .unauthorized(canRequest: true)),
            (.unauthorized, .denied, .unauthorized(canRequest: false)),
            (.unauthorized, .restricted, .unauthorized(canRequest: false)),
            (.poweredOff, .allowedAlways, .poweredOff),
            (.poweredOn, .allowedAlways, .ready),
        ]
        for (state, authorization, expected) in cases {
            XCTAssertEqual(AdapterMonitor.map(state: state, authorization: authorization), expected, "\(state) \(authorization)")
        }
        // 권한이 거부되면 manager 상태가 무엇이든 canRequest 는 false
        XCTAssertEqual(AdapterMonitor.map(state: .unknown, authorization: .denied), .unauthorized(canRequest: false))
    }

    @BLECoreActor
    func testAdapterStatesIsUnknownBeforeStartThenFollowsCentral() async throws {
        let central = Support.makeCentral()
        let client = Support.makeClient { central }
        var iterator = client.adapterStates.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first, .unknown)
        client.start()
        let second = await iterator.next()
        XCTAssertEqual(second, .ready)
        central.setAdapter(.poweredOff)
        let third = await iterator.next()
        XCTAssertEqual(third, .poweredOff)
        client.close()
    }

    // MARK: 대기 상한

    @BLECoreActor
    func testUnknownBeforeStartFailsAfterTwoSeconds() async {
        let central = Support.makeCentral(state: .unknown, authorization: .notDetermined)
        let client = Support.makeClient { central }
        let probe = GateProbe(client.runtime)
        await Support.sleep(realMilliseconds: Support.realMilliseconds(1500))
        XCTAssertNil(probe.result, "2000ms 전에는 기다린다")
        let result = await probe.wait()
        XCTAssertEqual(result, "ADAPTER_UNAVAILABLE")
        client.close()
    }

    @BLECoreActor
    func testStartWithinTwoSecondsLetsCommandProceed() async {
        let central = Support.makeCentral()
        let client = Support.makeClient { central }
        let probe = GateProbe(client.runtime)
        await Support.sleep(realMilliseconds: Support.realMilliseconds(500))
        XCTAssertNil(probe.result)
        client.start()
        let result = await probe.wait()
        XCTAssertEqual(result, "ok")
        client.close()
    }

    @BLECoreActor
    func testNotDeterminedAfterStartWaitsPastTwoSeconds() async {
        let central = Support.makeCentral(state: .unknown, authorization: .notDetermined)
        let client = Support.makeClient { central }
        client.start()
        let probe = GateProbe(client.runtime)
        await Support.sleep(realMilliseconds: Support.realMilliseconds(3000))
        XCTAssertNil(probe.result, "권한 팝업 동안은 2000ms 를 넘겨도 기다린다")
        central.setAdapter(.poweredOn, authorization: .allowedAlways)
        let result = await probe.wait()
        XCTAssertEqual(result, "ok")
        client.close()
    }

    @BLECoreActor
    func testPermissionDeniedAfterPopupFailsCommand() async {
        let central = Support.makeCentral(state: .unknown, authorization: .notDetermined)
        let client = Support.makeClient { central }
        client.start()
        let probe = GateProbe(client.runtime)
        await Support.sleep(realMilliseconds: Support.realMilliseconds(2500))
        XCTAssertNil(probe.result)
        central.setAdapter(.unauthorized, authorization: .denied)
        let result = await probe.wait()
        XCTAssertEqual(result, "PERMISSION_DENIED")
        client.close()
    }

    @BLECoreActor
    func testUnknownStaysCappedWhenAuthorizationDeterminedButStateUnknown() async {
        let central = Support.makeCentral(state: .unknown, authorization: .allowedAlways)
        let client = Support.makeClient { central }
        client.start()
        let probe = GateProbe(client.runtime)
        let result = await probe.wait()
        XCTAssertEqual(result, "ADAPTER_UNAVAILABLE")
        client.close()
    }

    // MARK: 즉시 판정

    @BLECoreActor
    func testImmediateVerdicts() async {
        let cases: [(CentralPortState, PortAuthorization, String)] = [
            (.poweredOn, .allowedAlways, "ok"),
            (.poweredOff, .allowedAlways, "ADAPTER_UNAVAILABLE"),
            (.resetting, .allowedAlways, "ADAPTER_UNAVAILABLE"),
            (.unauthorized, .denied, "PERMISSION_DENIED"),
            (.unauthorized, .restricted, "PERMISSION_DENIED"),
            (.unsupported, .allowedAlways, "BLE_UNSUPPORTED"),
        ]
        for (state, authorization, expected) in cases {
            let central = Support.makeCentral(state: state, authorization: authorization)
            let client = Support.makeClient { central }
            client.start()
            let result = await GateProbe(client.runtime).wait()
            XCTAssertEqual(result, expected, "\(state) \(authorization)")
            client.close()
        }
    }

    // MARK: 사용 설명 키

    @BLECoreActor
    func testMissingUsageDescriptionPublishesUnauthorizedWithoutCreatingManager() async {
        final class Counter: @unchecked Sendable { var created = 0 }
        let counter = Counter()
        let client = Support.makeClient(environment: BLEEnvironment(hasBluetoothUsageDescription: false)) {
            counter.created += 1
            return Support.makeCentral()
        }
        client.start()
        var iterator = client.adapterStates.makeAsyncIterator()
        let state = await iterator.next()
        XCTAssertEqual(state, .unauthorized(canRequest: false))
        let result = await GateProbe(client.runtime).wait()
        XCTAssertEqual(result, "PERMISSION_DENIED")
        XCTAssertEqual(counter.created, 0)
        client.close()
    }

    // MARK: 취소와 닫기

    @BLECoreActor
    func testCallerCancellationEndsTheWait() async {
        let central = Support.makeCentral(state: .unknown, authorization: .notDetermined)
        let client = Support.makeClient { central }
        client.start()
        let probe = GateProbe(client.runtime)
        await Support.sleep(realMilliseconds: 50)
        probe.cancel()
        let result = await probe.wait()
        XCTAssertEqual(result, "cancelled")
        client.close()
    }

    /// 게시 도중 observer 가 대기 중인 gate 를 취소하면 취소가 이긴다(0.2.0: observer 가 판정보다 먼저 돌았다)
    @BLECoreActor
    func testCancelInsideObserverWinsOverVerdict() async {
        let central = Support.makeCentral(state: .unknown, authorization: .notDetermined)
        let client = Support.makeClient { central }
        client.start()
        let gate = client.runtime.adapter.gate()
        client.runtime.adapter.observe { _ in gate.cancel() }
        central.setAdapter(.poweredOff, authorization: .allowedAlways)
        var cancelled = false
        do { try await gate.value() } catch is CancellationError { cancelled = true } catch {}
        XCTAssertTrue(cancelled)
        client.close()
    }

    @BLECoreActor
    func testCloseEndsPendingWaitWithClientClosed() async {
        let central = Support.makeCentral(state: .unknown, authorization: .notDetermined)
        let client = Support.makeClient { central }
        client.start()
        let probe = GateProbe(client.runtime)
        await Support.sleep(realMilliseconds: 50)
        client.close()
        let result = await probe.wait()
        XCTAssertEqual(result, "CLIENT_CLOSED")
    }
}
