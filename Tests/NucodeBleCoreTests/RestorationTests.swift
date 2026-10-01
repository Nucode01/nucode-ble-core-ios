import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// 앱 시작 등록과 상태 복원 (docs/v1/ios-design.md §8·§9). 가짜 central 이 `willRestoreState` 를 흉내 낸다.
@BLECoreActor
final class RestorationTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID

    private final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(PeripheralID, CharacteristicRef, Data)] = []
        func add(_ id: PeripheralID, _ ref: CharacteristicRef, _ data: Data) {
            lock.lock(); items.append((id, ref, data)); lock.unlock()
        }
        var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
        var first: (PeripheralID, CharacteristicRef, Data)? { lock.lock(); defer { lock.unlock() }; return items.first }
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

    private func isReady(_ session: Session) -> Bool {
        if case .ready = session.state.value { return true }
        return false
    }

    private func makeCentral(state: CentralPortState = .poweredOn) throws -> FakeCentral {
        let dir = ContractDirectory.locate(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        return FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale), state: state)
    }

    private func linkedPeripheral(_ central: FakeCentral) async -> Bool {
        central.connect(central.peripheral)
        return await waitUntil { central.peripheral.connectionState == .connected }
    }

    // MARK: 등록 기기 채택

    func testRestoredRegisteredDeviceIsAdoptedAndReachesReadyAtPoweredOn() async throws {
        let central = try makeCentral(state: .poweredOff)
        let client = Support.makeClient { central }
        let value = central.peripheral.characteristicRef("probe.value")
        client.register(id, options: ConnectOptions(), subscribe: [value])
        client.start()
        let session = client.runtime.registry.session(for: id)
        XCTAssertNil(session.peripheral)
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        XCTAssertTrue(session.peripheral === central.peripheral, "등록 기기는 session.peripheral 로 받아둔다")
        guard case .disconnected(reason: .initial) = session.state.value else { return XCTFail("복원은 상태를 바꾸지 않는다") }

        central.setAdapter(.poweredOn)
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        XCTAssertEqual(session.activeSubscriptionsFlow.value, [value], "등록한 구독 의도가 복원된다")
        client.close()
    }

    func testRestoredAlreadyConnectedPeripheralTakesTheSamePath() async throws {
        let central = try makeCentral()
        let linked = await linkedPeripheral(central)
        XCTAssertTrue(linked)
        let client = Support.makeClient { central }
        client.register(id, options: ConnectOptions(), subscribe: [])
        client.start()
        // 연결 경로는 Task 로 시작하므로 같은 동기 구간에서 온 복원 콜백이 먼저 처리된다
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        let session = client.runtime.registry.session(for: id)
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        client.close()
    }

    func testUnregisteredRestoredPeripheralIsCancelled() async throws {
        let central = try makeCentral()
        let linked = await linkedPeripheral(central)
        XCTAssertTrue(linked)
        let client = Support.makeClient { central }
        client.start()
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        let dropped = await waitUntil { central.peripheral.connectionState != .connected }
        XCTAssertTrue(dropped, "미등록 기기는 cancelPeripheralConnection 된다")
        XCTAssertTrue(client.runtime.registry.sessions.isEmpty)
        client.close()
    }

    // MARK: 복원 콜백은 poweredOn 전에 온다 (CoreBluetooth 는 그 사이 명령을 무시한다)

    /// 앱이 새로 떴을 때의 모양: OS 가 링크를 쥔 채 새 manager 는 `unknown` 으로 시작하고, 복원 콜백이 상태 콜백보다 먼저 온다
    private func relaunchedWithLink() async throws -> FakeCentral {
        let central = try makeCentral()
        let linked = await linkedPeripheral(central)
        XCTAssertTrue(linked)
        central.relaunchProcess()
        return central
    }

    func testUnregisteredRestoredPeripheralIsCancelledOncePoweredOn() async throws {
        let central = try await relaunchedWithLink()
        let client = Support.makeClient { central }
        client.start()
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        XCTAssertEqual(central.misuses, [], "poweredOn 전에는 명령을 내지 않는다(CB 가 무시한다)")
        XCTAssertEqual(central.peripheral.connectionState, .connected)

        central.setAdapter(.poweredOn)
        let dropped = await waitUntil { central.peripheral.connectionState == .disconnected }
        XCTAssertTrue(dropped, "첫 poweredOn 에서 미등록 복원 기기를 끊는다")
        XCTAssertEqual(central.commands.filter { $0 == "cancelPeripheralConnection" }.count, 1)
        XCTAssertEqual(central.misuses, [])
        XCTAssertTrue(client.runtime.registry.sessions.isEmpty)
        client.close()
    }

    func testPendingRestoredCancelIsDroppedWhenFirstStateIsNotPoweredOn() async throws {
        for first in [CentralPortState.poweredOff, .unauthorized] {
            let central = try await relaunchedWithLink()
            let client = Support.makeClient { central }
            client.start()
            central.delegate?.central(central, willRestoreState: [central.peripheral])
            central.setAdapter(first, authorization: first == .unauthorized ? .denied : .allowedAlways)
            // 상태 콜백은 나중에 나가고 그때의 상태를 읽으므로, 첫 상태가 core 에 닿은 뒤에 켠다
            let seen = await waitUntil { client.runtime.adapter.current != .unknown }
            XCTAssertTrue(seen)
            central.setAdapter(.poweredOn)
            let on = await waitUntil { client.runtime.adapter.current == .ready }
            XCTAssertTrue(on)
            // 그사이 앱이 같은 기기에 다시 붙어도 남은 취소가 끊지 않는다
            let session = try client.runtime.session(for: id)
            try await client.runtime.connect(session, options: ConnectOptions())
            let ready = await waitUntil { isReady(session) }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(ready && isReady(session), "\(first): 남은 취소가 새 연결을 끊었다")
            XCTAssertEqual(central.misuses, [], "\(first)")
            XCTAssertFalse(central.commands.contains("cancelPeripheralConnection"), "\(first): 명령 없이 버린다")
            client.close()
        }
    }

    func testRestoredPeripheralClaimedByAppConnectBeforePoweredOnIsNotCancelled() async throws {
        let central = try await relaunchedWithLink()
        let client = Support.makeClient { central }
        client.start()
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        let session = try client.runtime.session(for: id)
        let connecting = Task { @BLECoreActor in try await client.runtime.connect(session, options: ConnectOptions()) }
        try await Task.sleep(for: .milliseconds(20))
        central.setAdapter(.poweredOn)
        try await connecting.value
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        XCTAssertFalse(central.commands.contains("cancelPeripheralConnection"), "앱이 세션을 만든 기기는 그 세션이 주인이다")
        XCTAssertEqual(central.misuses, [])
        client.close()
    }

    func testRegisteredRestoredLinkIsNotCancelledAcrossPoweredOn() async throws {
        let central = try await relaunchedWithLink()
        let client = Support.makeClient { central }
        client.register(id, options: ConnectOptions(), subscribe: [])
        client.start()
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        central.setAdapter(.poweredOn)
        let session = client.runtime.registry.session(for: id)
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        XCTAssertFalse(central.commands.contains("cancelPeripheralConnection"), "등록 기기는 끊지 않는다")
        XCTAssertEqual(central.misuses, [])
        client.close()
    }

    // MARK: 알림

    func testNotificationRightAfterRestoreGoesToHandler() async throws {
        let central = try makeCentral(state: .poweredOff)
        let client = Support.makeClient { central }
        let value = central.peripheral.characteristicRef("probe.value")
        let received = Received()
        let queue = DispatchQueue(label: "app.notifications")
        client.register(id, options: ConnectOptions(), subscribe: [value])
        client.onNotification(queue: queue) { id, ref, data in received.add(id, ref, data) }
        client.start()
        central.delegate?.central(central, willRestoreState: [central.peripheral])
        // poweredOn 도, 세션 단계도 없는 채로 온 값
        central.peripheral.delegate?.peripheral(central.peripheral, didUpdateValue: Data([9]), for: value, error: nil)
        let arrived = await waitUntil { received.count == 1 }
        XCTAssertTrue(arrived)
        XCTAssertEqual(received.first?.0, id)
        XCTAssertEqual(received.first?.1, value)
        XCTAssertEqual(received.first?.2, Data([9]))
        client.close()
    }

    func testNotificationInAnySessionStageGoesToHandler() async throws {
        let central = try makeCentral()
        let client = Support.makeClient { central }
        let value = central.peripheral.characteristicRef("probe.value")
        let received = Received()
        client.register(id, options: ConnectOptions(), subscribe: [value])
        client.onNotification(queue: DispatchQueue(label: "app.notifications")) { id, ref, data in received.add(id, ref, data) }
        client.start()
        let session = client.runtime.registry.session(for: id)
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        central.peripheral.notify(count: 2)
        let arrived = await waitUntil { received.count == 2 }
        XCTAssertTrue(arrived)
        client.close()
    }

    // MARK: 스캔

    func testRegisteredScanIsRestoredAndUnregisteredScanIsStopped() async throws {
        let nus = try XCTUnwrap(BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e"))
        let request = ScanRequest(filter: ScanFilter(serviceUUIDs: [nus]))

        let restoredCentral = try makeCentral()
        let withScan = Support.makeClient { restoredCentral }
        withScan.registerScan(request)
        withScan.start()
        restoredCentral.scanForPeripherals(services: [nus], allowDuplicates: false)
        restoredCentral.delegate?.central(restoredCentral, willRestoreState: [])
        XCTAssertTrue(restoredCentral.isScanning)
        XCTAssertEqual(withScan.runtime.scanner.request, request)
        withScan.close()

        let stoppedCentral = try makeCentral()
        let withoutScan = Support.makeClient { stoppedCentral }
        withoutScan.start()
        stoppedCentral.scanForPeripherals(services: [nus], allowDuplicates: false)
        XCTAssertTrue(stoppedCentral.isScanning)
        stoppedCentral.delegate?.central(stoppedCentral, willRestoreState: [])
        XCTAssertFalse(stoppedCentral.isScanning, "등록 스캔이 없으면 복원된 스캔은 멈춘다")
        withoutScan.close()
    }

    // MARK: 같은 연결 경로

    func testRegisterAndConnectAfterStartMakeTheSameTransitions() async throws {
        func transitions(_ body: (DefaultBLEClient) async throws -> Void) async throws -> [String] {
            let central = try makeCentral()
            let client = Support.makeClient { central }
            let stream = client.events
            try await body(client)
            let session = client.runtime.registry.session(for: id)
            _ = await waitUntil { isReady(session) }
            client.close()
            var seen: [String] = []
            for await event in stream {
                if case .connection(_, let state) = event { seen.append(String(describing: state)) }
            }
            return seen
        }
        let registered = try await transitions { client in
            client.register(self.id, options: ConnectOptions(), subscribe: [])
            client.start()
        }
        let manual = try await transitions { client in
            client.start()
            _ = try await client.connect(self.id, options: ConnectOptions())
        }
        XCTAssertEqual(registered, manual)
        XCTAssertEqual(registered.last, "ready")
    }

    func testRegisteredDeviceThatCannotBeFoundEndsDisconnectedFailedWithDiagnostic() async throws {
        let central = try makeCentral()
        let client = Support.makeClient { central }
        let unknown = PeripheralID(rawValue: "not-there")
        client.register(unknown, options: ConnectOptions(), subscribe: [])
        client.start()
        let session = client.runtime.registry.session(for: unknown)
        let failed = await waitUntil {
            if case .disconnected(reason: .failed(let failure)) = session.state.value { return failure.code == .peripheralNotFound }
            return false
        }
        XCTAssertTrue(failed)
        client.close()
    }
}
