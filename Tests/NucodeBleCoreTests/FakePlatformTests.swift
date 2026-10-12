import BleContract
import BleCoreFakes
import Dispatch
import Foundation
import XCTest
@testable import NucodeBleCore

/// 델리게이트 콜백을 기록한다. 모든 콜백이 core 큐에서 오는지도 본다.
@BLECoreActor
private final class Recorder: CentralPortDelegate, PeripheralPortDelegate {
    var stateUpdates = 0
    var discoveries: [(name: String?, services: Set<BLEUUID>)] = []
    var connects = 0
    var disconnects: [PortError?] = []
    var notificationStates: [Bool] = []
    var values: [Data?] = []
    var writes = 0
    var readyCalls = 0
    var services: [NucodeBleCore.ServiceRef] = []

    func centralDidUpdateState(_ central: any CentralPort) {
        onCoreQueue()
        stateUpdates += 1
    }

    func central(_ central: any CentralPort, didDiscover peripheral: any PeripheralPort, advertisement: AdvertisementData, rssi: Int) {
        onCoreQueue()
        discoveries.append((advertisement.localName, advertisement.serviceUUIDs))
    }

    func central(_ central: any CentralPort, didConnect peripheral: any PeripheralPort) {
        onCoreQueue()
        connects += 1
    }

    func central(_ central: any CentralPort, didFailToConnect peripheral: any PeripheralPort, error: PortError?) {}

    func central(_ central: any CentralPort, didDisconnect peripheral: any PeripheralPort, error: PortError?) {
        onCoreQueue()
        disconnects.append(error)
    }

    func central(_ central: any CentralPort, willRestoreState peripherals: [any PeripheralPort]) {}

    func peripheral(_ peripheral: any PeripheralPort, didDiscoverServices services: [NucodeBleCore.ServiceRef], error: PortError?) {
        onCoreQueue()
        self.services = services
    }

    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverCharacteristics characteristics: [DiscoveredCharacteristic],
        for service: NucodeBleCore.ServiceRef,
        error: PortError?
    ) {}

    func peripheral(_ peripheral: any PeripheralPort, didUpdateValue value: Data?, for characteristic: CharacteristicRef, error: PortError?) {
        onCoreQueue()
        values.append(value)
    }

    func peripheral(_ peripheral: any PeripheralPort, didWriteValueFor characteristic: CharacteristicRef, error: PortError?) {
        onCoreQueue()
        writes += 1
    }

    func peripheral(
        _ peripheral: any PeripheralPort,
        didUpdateNotificationState isNotifying: Bool,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        onCoreQueue()
        notificationStates.append(isNotifying)
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: any PeripheralPort) {
        onCoreQueue()
        readyCalls += 1
    }

    private nonisolated func onCoreQueue() {
        dispatchPrecondition(condition: .onQueue(bleCoreQueue))
    }
}

private struct Rig {
    let central: FakeCentral
    let device: FakePeripheral
    let recorder: Recorder
}

final class FakePlatformTests: XCTestCase {
    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    @BLECoreActor
    private func makeRig() throws -> Rig {
        let dir = ContractDirectory.locate(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec)
        let recorder = Recorder()
        central.delegate = recorder
        central.peripheral.delegate = recorder
        return Rig(central: central, device: central.peripheral, recorder: recorder)
    }

    /// 조건이 참이 될 때까지 기다린다(실제 시간, 기본 5초)
    @BLECoreActor
    private func waitUntil(_ what: String, timeoutMs: Int = 5000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition() {
            if waited >= timeoutMs { return XCTFail("timeout: \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
    }

    @BLECoreActor
    private func connect(_ rig: Rig) async {
        rig.central.connect(rig.device)
        await waitUntil("didConnect") { rig.recorder.connects >= 1 }
    }

    private func pattern(_ range: Range<Int>) -> Data {
        Data(range.map { UInt8(truncatingIfNeeded: $0) })
    }

    // MARK: 어댑터와 처음 보는 기기

    @BLECoreActor
    func testStartsReadyAndAuthorized() async throws {
        let rig = try makeRig()
        XCTAssertEqual(rig.central.state, .poweredOn)
        XCTAssertEqual(rig.central.authorization, .allowedAlways)
    }

    @BLECoreActor
    func testUnknownIDHasNoRetrieveResultBeforeScan() async throws {
        let rig = try makeRig()
        XCTAssertTrue(rig.central.retrievePeripherals(withIdentifiers: [rig.device.id]).isEmpty)
        XCTAssertTrue(rig.central.retrieveConnectedPeripherals(withServices: []).isEmpty)
        rig.central.scanForPeripherals(services: nil, allowDuplicates: false)
        await waitUntil("first scan result") { !rig.recorder.discoveries.isEmpty }
        rig.central.stopScan()
        XCTAssertEqual(rig.central.retrievePeripherals(withIdentifiers: [rig.device.id]).count, 1)
        XCTAssertTrue(rig.central.retrievePeripherals(withIdentifiers: [PeripheralID(rawValue: "other")]).isEmpty)
    }

    // MARK: 광고와 스캔

    @BLECoreActor
    func testScanFiltersByAdvertisedServiceAndReportsNameAndServices() async throws {
        let rig = try makeRig()
        let probeService = rig.device.characteristicRef("probe.value").service.uuid
        let nusService = rig.device.characteristicRef("nus.rx").service.uuid

        rig.central.scanForPeripherals(services: [probeService], allowDuplicates: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(rig.recorder.discoveries.isEmpty, "probe 서비스는 광고에 없다")

        rig.central.scanForPeripherals(services: [nusService], allowDuplicates: false)
        await waitUntil("filtered result") { !rig.recorder.discoveries.isEmpty }
        XCTAssertEqual(rig.recorder.discoveries.first?.name, "Nordic_UART_Service")
        XCTAssertEqual(rig.recorder.discoveries.first?.services, [nusService])
    }

    @BLECoreActor
    func testNoAdvertisingWhileHiddenAndPendingConnectAttachesWhenItEnds() async throws {
        let rig = try makeRig()
        await connect(rig)
        rig.device.linkDropHide(milliseconds: 700)
        await waitUntil("link drop") { !rig.recorder.disconnects.isEmpty }
        XCTAssertNotNil(rig.recorder.disconnects.first ?? nil, "원격 종료는 오류가 있다")
        XCTAssertFalse(rig.device.isAdvertising)

        rig.central.scanForPeripherals(services: nil, allowDuplicates: false)
        rig.central.connect(rig.device)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(rig.recorder.discoveries.isEmpty, "숨김 중에는 광고가 없다")
        XCTAssertEqual(rig.recorder.connects, 1, "대기 connect 는 붙지 않는다")

        await waitUntil("광고 재개 뒤 결과") { !rig.recorder.discoveries.isEmpty }
        await waitUntil("대기 connect 가 붙음") { rig.recorder.connects == 2 }
    }

    @BLECoreActor
    func testNoAdvertisingWhileLinked() async throws {
        let rig = try makeRig()
        await connect(rig)
        rig.central.scanForPeripherals(services: nil, allowDuplicates: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertTrue(rig.recorder.discoveries.isEmpty)
    }

    // MARK: 재호출

    @BLECoreActor
    func testConnectAgainAndNotifyAgainCallBackAgain() async throws {
        let rig = try makeRig()
        await connect(rig)
        rig.central.connect(rig.device)
        await waitUntil("didConnect again") { rig.recorder.connects == 2 }

        let value = rig.device.characteristicRef("probe.value")
        rig.device.setNotifyValue(true, for: value)
        rig.device.setNotifyValue(true, for: value)
        await waitUntil("notify state twice") { rig.recorder.notificationStates == [true, true] }
    }

    @BLECoreActor
    func testDiscoverServicesAndMTU() async throws {
        let rig = try makeRig()
        await connect(rig)
        rig.device.discoverServices(nil)
        await waitUntil("services") { rig.recorder.services.count == 2 }
        XCTAssertEqual(rig.device.maximumWriteValueLength(for: .withoutResponse), 62)
        XCTAssertEqual(rig.device.maximumWriteValueLength(for: .withResponse), 512)
    }

    @BLECoreActor
    func testReadNotifyDeliversNotificationBeforeReadResponse() async throws {
        let rig = try makeRig()
        await connect(rig)
        let value = rig.device.characteristicRef("probe.value")
        rig.device.setNotifyValue(true, for: value)
        await waitUntil("subscribed") { rig.recorder.notificationStates == [true] }
        rig.device.readNotify(on: true)
        rig.device.readValue(for: value)
        await waitUntil("notification and read response") { rig.recorder.values.count == 2 }
        rig.device.notify(count: 2)
        await waitUntil("two notifications") { rig.recorder.values.count == 4 }
        XCTAssertEqual(rig.recorder.writes, 0)
    }

    // MARK: 쓰기

    @BLECoreActor
    func testLongWriteWithResponseTakesAboutOneSecond() async throws {
        let rig = try makeRig()
        await connect(rig)
        let rx = rig.device.characteristicRef("nus.rx")
        var data = Data()
        for chunk in 0..<8 { data.append(pattern(chunk * 512..<(chunk + 1) * 512)) }
        for chunk in 0..<8 { rig.device.writeValue(data.subdata(in: chunk * 512..<(chunk + 1) * 512), for: rx, type: .withResponse) }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThan(rig.recorder.writes, 8, "300ms 에는 아직 진행 중")
        XCTAssertGreaterThan(rig.device.rxReport.count, 0)
        XCTAssertLessThan(rig.device.rxReport.count, 4096)

        await waitUntil("all chunks answered", timeoutMs: 4000) { rig.recorder.writes == 8 }
        XCTAssertEqual(rig.device.rxCheckLine, "4096 ok")
    }

    @BLECoreActor
    func testWithoutResponseHonoringFlowControlIsComplete() async throws {
        let rig = try makeRig()
        await connect(rig)
        let rx = rig.device.characteristicRef("nus.rx")
        for chunk in 0..<60 {
            if !rig.device.canSendWriteWithoutResponse {
                await waitUntil("peripheralIsReady") { rig.device.canSendWriteWithoutResponse }
            }
            rig.device.writeValue(pattern(chunk * 62..<(chunk + 1) * 62), for: rx, type: .withoutResponse)
        }
        await waitUntil("drain") { rig.device.rxReport.count == 60 * 62 }
        XCTAssertEqual(rig.device.rxCheckLine, "3720 ok")
        XCTAssertGreaterThan(rig.recorder.readyCalls, 0)
    }

    @BLECoreActor
    func testWithoutResponseIgnoringFlowControlIsBad() async throws {
        let rig = try makeRig()
        await connect(rig)
        let rx = rig.device.characteristicRef("nus.rx")
        // 흐름 제어를 무시하고 쓴다: 가득 찬 동안 쓴 조각은 버려지고 그 뒤 조각은 받아서 순서가 어긋난다
        for chunk in 0..<60 {
            rig.device.writeValue(pattern(chunk * 62..<(chunk + 1) * 62), for: rx, type: .withoutResponse)
            try await Task.sleep(for: .milliseconds(1))
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(rig.device.rxReport.count < 60 * 62)
        XCTAssertTrue(rig.device.rxCheckLine.hasSuffix(" bad"), rig.device.rxCheckLine)
    }

    @BLECoreActor
    func testRxCountResetsPerConnection() async throws {
        let rig = try makeRig()
        await connect(rig)
        let rx = rig.device.characteristicRef("nus.rx")
        rig.device.writeValue(pattern(0..<10), for: rx, type: .withResponse)
        await waitUntil("write") { rig.recorder.writes == 1 }
        XCTAssertEqual(rig.device.rxCheckLine, "10 ok")
        rig.central.cancelPeripheralConnection(rig.device)
        await waitUntil("disconnect") { rig.recorder.disconnects.count == 1 }
        XCTAssertEqual(rig.recorder.disconnects.first ?? nil, nil, "요청한 해제는 오류가 없다")
        await connect2(rig)
        XCTAssertEqual(rig.device.rxCheckLine, "0 ok")
    }

    @BLECoreActor
    private func connect2(_ rig: Rig) async {
        rig.central.connect(rig.device)
        await waitUntil("second didConnect") { rig.recorder.connects == 2 }
    }

    // MARK: 어댑터

    @BLECoreActor
    func testAdapterOffReportsStateThenDropsLinkAndStopsScan() async throws {
        let rig = try makeRig()
        await connect(rig)
        rig.central.scanForPeripherals(services: nil, allowDuplicates: false)
        rig.central.setAdapter(.poweredOff)
        await waitUntil("state callback") { rig.recorder.stateUpdates == 1 }
        await waitUntil("link dropped") { rig.recorder.disconnects.count == 1 }
        XCTAssertEqual(rig.central.state, .poweredOff)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(rig.recorder.discoveries.isEmpty)
    }

    // MARK: 시계, 환경

    func testScaledClockScalesSleep() async throws {
        let clock = ScaledClock(scale: 0.1)
        let start = ContinuousClock.now
        try await clock.sleep(milliseconds: 500)
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(300))
        XCTAssertGreaterThanOrEqual(clock.nowMilliseconds(), 40)
    }

    func testEnvironmentReadsBundleKeys() {
        let env = BLEEnvironment(hasBluetoothUsageDescription: true, backgroundModes: ["bluetooth-central"])
        XCTAssertTrue(env.hasBluetoothCentralBackgroundMode)
        XCTAssertFalse(BLEEnvironment(hasBluetoothUsageDescription: false).hasBluetoothCentralBackgroundMode)
    }
}
