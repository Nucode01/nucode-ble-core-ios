import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// Ready 뒤 링크 유실, Recovering, 어댑터 이탈과 복귀(contract/states.md §2·§3)
@BLECoreActor
final class LinkLossTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID

    private func describe(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected(let reason):
            switch reason {
            case .initial: return "Disconnected(Initial)"
            case .requested: return "Disconnected(Requested)"
            case .clientClosed: return "Disconnected(ClientClosed)"
            case .failed(let failure): return "Disconnected(Failed:\(failure.code.value))"
            }
        case .connecting: return "Connecting"
        case .discoveringServices: return "DiscoveringServices"
        case .configuring: return "Configuring"
        case .ready: return "Ready"
        case .disconnecting: return "Disconnecting"
        case .recovering(let failure): return "Recovering(\(failure.code.value))"
        }
    }

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private var events: AsyncStream<BLEEvent>?

    private func makeReady(autoReconnect: Bool) async throws -> (BLEClient, FakeCentral, Session) {
        let dir = ContractDirectory.locate(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        events = client.events
        _ = try await client.connect(id, options: ConnectOptions(autoReconnect: autoReconnect))
        let session = client.runtime.registry.session(for: id)
        let ready = await waitUntil { if case .ready = session.state.value { return true } else { return false } }
        XCTAssertTrue(ready)
        return (client, central, session)
    }

    private func isReady(_ session: Session) -> Bool {
        if case .ready = session.state.value { return true }
        return false
    }

    private func history(_ client: BLEClient, _ session: Session) async -> [String] {
        let stream = events
        client.close()
        var names: [String] = []
        if let stream {
            for await event in stream { if case .connection(_, let state) = event { names.append(describe(state)) } }
        }
        return names
    }

    func testLinkDropWithoutAutoReconnectFailsWithLinkFailed() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: false)
        central.peripheral.linkDrop()
        let ended = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertTrue(ended)
        XCTAssertEqual(describe(session.state.value), "Disconnected(Failed:LINK_FAILED)")
        if case .disconnected(.failed(let failure)) = session.state.value {
            XCTAssertEqual(failure.platformDetail?.ios?.code, 7)
        }
    }

    func testLinkDropWithAutoReconnectRecoversWithoutConnecting() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        central.peripheral.linkDropHide(milliseconds: 500)
        let recovering = await waitUntil {
            if case .recovering = session.state.value { return true } else { return false }
        }
        XCTAssertTrue(recovering)
        let back = await waitUntil { isReady(session) }
        XCTAssertTrue(back)
        let names = await history(client, session)
        XCTAssertEqual(names, [
            "Connecting", "DiscoveringServices", "Configuring", "Ready",
            "Recovering(LINK_FAILED)", "DiscoveringServices", "Configuring", "Ready",
        ])
    }

    func testDisconnectWhileRecoveringEndsRequested() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        central.peripheral.linkDropHide(milliseconds: 100_000)
        let recovering = await waitUntil {
            if case .recovering = session.state.value { return true } else { return false }
        }
        XCTAssertTrue(recovering)
        await session.disconnect()
        XCTAssertEqual(describe(session.state.value), "Disconnected(Requested)")
        client.close()
    }

    func testAdapterOffEndsSessionAndReturnReconnectsOnce() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        central.setAdapter(.poweredOff)
        let ended = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertTrue(ended)
        XCTAssertEqual(describe(session.state.value), "Disconnected(Failed:ADAPTER_UNAVAILABLE)")
        central.setAdapter(.poweredOn)
        let back = await waitUntil { isReady(session) }
        XCTAssertTrue(back)
        let names = await history(client, session)
        XCTAssertEqual(names, [
            "Connecting", "DiscoveringServices", "Configuring", "Ready",
            "Disconnected(Failed:ADAPTER_UNAVAILABLE)", "Connecting", "DiscoveringServices", "Configuring", "Ready",
        ])
    }

    func testAdapterOffWithoutAutoReconnectDoesNotReturn() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: false)
        central.setAdapter(.poweredOff)
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        central.setAdapter(.poweredOn)
        await Support.sleep(realMilliseconds: 300)
        XCTAssertEqual(describe(session.state.value), "Disconnected(Failed:ADAPTER_UNAVAILABLE)")
        client.close()
    }

    func testPermissionLossEndsWithPermissionDenied() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        central.setAdapter(.unauthorized, authorization: .denied)
        let ended = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertTrue(ended)
        XCTAssertEqual(describe(session.state.value), "Disconnected(Failed:PERMISSION_DENIED)")
        client.close()
    }

    func testUserDisconnectCancelsAdapterReturnReconnect() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        central.setAdapter(.poweredOff)
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        await session.disconnect()
        central.setAdapter(.poweredOn)
        await Support.sleep(realMilliseconds: 300)
        XCTAssertEqual(describe(session.state.value), "Disconnected(Failed:ADAPTER_UNAVAILABLE)")
        client.close()
    }
}
