import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// readRSSI (CANDIDATE-34, api-contract §RSSI 계약, states.md §5 진입 검사 1~3·§8·§10). 가짜 기기는 probe 정의를 쓴다.
/// 기한 5000ms 는 `ClientTestSupport.scale` 로 실제 250ms 다
@BLECoreActor
final class RSSICommandTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private func isReady(_ session: Session) -> Bool {
        if case .ready = session.state.value { return true }
        return false
    }

    private func makeClient() throws -> (DefaultBLEClient, FakeCentral, Session) {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        return (client, central, client.runtime.registry.session(for: id))
    }

    private func makeReady() async throws -> (DefaultBLEClient, FakeCentral, Session) {
        let (client, central, session) = try makeClient()
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        return (client, central, session)
    }

    /// dBm 이나 실패 코드, 취소는 `cancelled`
    private func rssi(_ session: Session) async -> String {
        do {
            return "\(try await session.readRSSI())"
        } catch let error as BLEError {
            return error.failure.code.value
        } catch is CancellationError {
            return "cancelled"
        } catch {
            return "other"
        }
    }

    // MARK: 진입 검사 1~3

    func testReadyReturnsDBmAndOtherwiseNotReady() async throws {
        let (client, _, session) = try makeClient()
        let before = await rssi(session)
        XCTAssertEqual(before, "NOT_READY")
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        let value = await rssi(session)
        XCTAssertEqual(value, "-50")
        await session.disconnect()
        let after = await rssi(session)
        XCTAssertEqual(after, "NOT_READY")
        client.close()
    }

    func testClosedClientIsCheckedBeforeAdapter() async throws {
        let (client, central, session) = try await makeReady()
        central.setAdapter(.poweredOff)
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        let off = await rssi(session)
        XCTAssertEqual(off, "ADAPTER_UNAVAILABLE")
        client.close()
        let closed = await rssi(session)
        XCTAssertEqual(closed, "CLIENT_CLOSED", "닫힘(1)이 어댑터(2)보다 먼저다")
    }

    // MARK: 차례

    func testOverlappingCallsShareOnePlatformRequest() async throws {
        let (client, central, session) = try await makeReady()
        let first = Task { @BLECoreActor in await self.rssi(session) }
        let second = Task { @BLECoreActor in await self.rssi(session) }
        let values = [await first.value, await second.value]
        XCTAssertEqual(values, ["-50", "-50"])
        XCTAssertEqual(central.peripheral.rssiRequests, 1, "같은 기기의 겹친 호출은 플랫폼 요청 하나의 결과를 나눠 받는다")
        client.close()
    }

    func testTimeoutKeepsConnectionReady() async throws {
        let (client, central, session) = try await makeReady()
        central.peripheral.answersRSSI = false
        let timedOut = await rssi(session)
        XCTAssertEqual(timedOut, "RSSI_READ_TIMEOUT")
        XCTAssertTrue(isReady(session), "RSSI 기한은 세션을 poison 하지 않는다")
        central.peripheral.answersRSSI = true
        let next = await rssi(session)
        XCTAssertEqual(next, "-50")
        client.close()
    }

    func testDisconnectDuringReadInvalidatesCaller() async throws {
        let (client, central, session) = try await makeReady()
        central.peripheral.answersRSSI = false
        let pending = Task { @BLECoreActor in await self.rssi(session) }
        _ = await waitUntil { central.peripheral.rssiRequests == 1 }
        await session.disconnect()
        let outcome = await pending.value
        XCTAssertEqual(outcome, "OPERATION_INVALIDATED")
        client.close()
    }

    func testCloseDuringReadIsClientClosed() async throws {
        let (client, central, session) = try await makeReady()
        central.peripheral.answersRSSI = false
        let pending = Task { @BLECoreActor in await self.rssi(session) }
        _ = await waitUntil { central.peripheral.rssiRequests == 1 }
        client.close()
        let outcome = await pending.value
        XCTAssertEqual(outcome, "CLIENT_CLOSED")
    }

    func testPlatformErrorIsGattStatusFailedWithDetail() async throws {
        let (client, central, session) = try await makeReady()
        central.peripheral.rssiError = PortError(domain: "CBErrorDomain", code: 7, message: "rssi failed")
        do {
            _ = try await session.readRSSI()
            XCTFail("실패해야 한다")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .gattStatusFailed)
            XCTAssertEqual(error.failure.platformDetail?.ios?.domain, "CBErrorDomain")
            XCTAssertEqual(error.failure.platformDetail?.ios?.code, 7)
        }
        client.close()
    }

    func testUnmeasuredValueIsReturnedAsIs() async throws {
        let (client, central, session) = try await makeReady()
        central.peripheral.rssiValue = 127
        let value = await rssi(session)
        XCTAssertEqual(value, "127", "iOS 127(측정 못함)도 버리지 않는다")
        client.close()
    }

    func testCancelledCallerOnlyDetaches() async throws {
        let (client, central, session) = try await makeReady()
        // 가짜 기기가 답하지 않게 두고, 플랫폼 결과는 아래에서 직접 낸다(취소가 결과보다 먼저 오게)
        central.peripheral.answersRSSI = false
        let pending = Task { @BLECoreActor in await self.rssi(session) }
        _ = await waitUntil { central.peripheral.rssiRequests == 1 }
        pending.cancel()
        let cancelled = await pending.value
        XCTAssertEqual(cancelled, "cancelled")
        let next = Task { @BLECoreActor in await self.rssi(session) }
        try await Task.sleep(for: .milliseconds(20))
        central.peripheral.delegate?.peripheral(central.peripheral, didReadRSSI: -50, error: nil)
        let nextValue = await next.value
        XCTAssertEqual(nextValue, "-50")
        XCTAssertEqual(central.peripheral.rssiRequests, 1, "취소 뒤의 호출은 같은 플랫폼 요청의 결과를 받는다")
        client.close()
    }

    func testDoesNotWaitForWriteInProgress() async throws {
        let (client, _, session) = try await makeReady()
        let rx = CharacteristicRef(
            service: ServiceRef(uuid: BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0),
            uuid: BLEUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")!,
            instanceIndex: 0
        )
        let value = Data((0..<8192).map { UInt8($0 % 256) })
        var order: [String] = []
        let write = Task { @BLECoreActor in
            let wrote = (try? await session.write(rx, value: value, options: WriteOptions())) != nil
            order.append(wrote ? "write" : "write failed")
        }
        try await Task.sleep(for: .milliseconds(10))
        let reading = await rssi(session)
        order.append("rssi")
        XCTAssertEqual(reading, "-50")
        await write.value
        XCTAssertEqual(order, ["rssi", "write"], "RSSI 는 GATT 큐 밖이라 진행 중인 write 를 기다리지 않는다")
        client.close()
    }

    // MARK: 차례 주인

    func testPublicFactoryUsesProcessTurnAndPackageClientsDoNot() async throws {
        let made = try XCTUnwrap(BLEClientFactory.make() as? DefaultBLEClient)
        XCTAssertTrue(made.runtime.registry.session(for: id).context.rssiTurn === RSSITurn.process)
        let one = Support.makeClient { Support.makeCentral() }
        let two = Support.makeClient { Support.makeCentral() }
        let turnOne = one.runtime.registry.session(for: id).context.rssiTurn
        let turnTwo = two.runtime.registry.session(for: id).context.rssiTurn
        XCTAssertFalse(turnOne === turnTwo)
        XCTAssertFalse(turnOne === RSSITurn.process)
        made.close()
        one.close()
        two.close()
    }
}
