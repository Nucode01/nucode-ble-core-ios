import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// 플랫폼 스캔 호출을 기록하는 central. 광고는 시험이 `deliver` 로 직접 넣는다(가짜 central 의 자동 광고를 쓰지 않는다).
@BLECoreActor
private final class RecordingCentral: CentralPort {
    struct ScanCall: Equatable {
        let services: [BLEUUID]?
        let allowDuplicates: Bool
    }

    let inner: FakeCentral
    var state: CentralPortState = .poweredOn
    var authorization: PortAuthorization = .allowedAlways
    weak var delegate: (any CentralPortDelegate)?
    var scanCalls: [ScanCall] = []
    var stopCalls = 0

    init(inner: FakeCentral) { self.inner = inner }

    var peripheral: FakePeripheral { inner.peripheral }

    func scanForPeripherals(services: [BLEUUID]?, allowDuplicates: Bool) {
        scanCalls.append(ScanCall(services: services, allowDuplicates: allowDuplicates))
    }

    func stopScan() { stopCalls += 1 }
    func retrievePeripherals(withIdentifiers identifiers: [PeripheralID]) -> [any PeripheralPort] { [] }
    func retrieveConnectedPeripherals(withServices services: [BLEUUID]) -> [any PeripheralPort] { [] }
    func connect(_ peripheral: any PeripheralPort) {}
    func cancelPeripheralConnection(_ peripheral: any PeripheralPort) {}

    func setAdapter(_ new: CentralPortState) {
        state = new
        delegate?.centralDidUpdateState(self)
    }

    func deliver(_ advertisement: AdvertisementData, rssi: Int = -50) {
        delegate?.central(self, didDiscover: inner.peripheral, advertisement: advertisement, rssi: rssi)
    }
}

final class ScannerTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let uuidA = BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!
    private static let uuidB = BLEUUID(string: "180f")!

    @BLECoreActor
    private func makeStarted(state: CentralPortState = .poweredOn) -> (DefaultBLEClient, RecordingCentral) {
        let central = RecordingCentral(inner: Support.makeCentral())
        central.state = state
        let client = Support.makeClient { central }
        client.start()
        return (client, central)
    }

    private func describe(_ state: ScanState) -> String {
        switch state {
        case .idle: return "Idle"
        case .scanning: return "Scanning"
        case .failed(let failure): return "Idle(Failed:\(failure.code.value))"
        }
    }

    @BLECoreActor
    private func scanState(_ client: DefaultBLEClient) -> String { describe(client.runtime.scanner.states.value) }

    private func request(name: String? = nil, services: [BLEUUID] = [], mode: ScanMode = .balanced) -> ScanRequest {
        ScanRequest(filter: ScanFilter(serviceUUIDs: services, namePrefix: name), options: ScanOptions(mode: mode))
    }

    // MARK: 시작과 중복

    @BLECoreActor
    func testSameRequestIsNoOpAndDifferentRequestFailsKeepingRunningScan() async throws {
        let (client, central) = makeStarted()
        try await client.startScan(request: request(name: "Nordic"))
        XCTAssertEqual(scanState(client), "Scanning")
        try await client.startScan(request: request(name: "Nordic"))
        XCTAssertEqual(central.scanCalls.count, 1, "같은 요청은 플랫폼을 다시 부르지 않는다")

        do {
            try await client.startScan(request: request(services: [Self.uuidA]))
            XCTFail("다른 요청은 실패해야 한다")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .scanAlreadyRunning)
        }
        XCTAssertEqual(scanState(client), "Scanning")
        XCTAssertEqual(central.scanCalls.count, 1)
        XCTAssertEqual(client.runtime.scanner.request, request(name: "Nordic"), "도는 스캔이 그대로다")

        await client.stopScan()
        XCTAssertEqual(scanState(client), "Idle")
        XCTAssertEqual(central.stopCalls, 1)
        await client.stopScan()
        XCTAssertEqual(central.stopCalls, 1, "stopScan 은 멱등이다")
        client.close()
    }

    @BLECoreActor
    func testPlatformFilterIsServiceUUIDsOnlyAndDuplicatesOnlyForLowLatency() async throws {
        let (client, central) = makeStarted()
        try await client.startScan(request: request(name: "x", services: [Self.uuidA], mode: .lowLatency))
        XCTAssertEqual(central.scanCalls, [.init(services: [Self.uuidA], allowDuplicates: true)])
        await client.stopScan()

        try await client.startScan(request: request(name: "x", mode: .balanced))
        XCTAssertEqual(central.scanCalls.last, .init(services: nil, allowDuplicates: false), "이름만 있으면 플랫폼 필터는 없다")
        await client.stopScan()
        try await client.startScan(request: request(mode: .lowPower))
        XCTAssertEqual(central.scanCalls.last?.allowDuplicates, false)
        client.close()
    }

    @BLECoreActor
    func testStartScanFollowsAdapterGate() async throws {
        let (client, central) = makeStarted(state: .poweredOff)
        do {
            try await client.startScan(request: request())
            XCTFail("꺼진 어댑터에서는 실패해야 한다")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .adapterUnavailable)
        }
        XCTAssertEqual(scanState(client), "Idle")
        XCTAssertTrue(central.scanCalls.isEmpty)
        client.close()

        do {
            try await client.startScan(request: request())
            XCTFail("닫힌 뒤에는 실패해야 한다")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .clientClosed)
        }
    }

    // MARK: 필터와 정규화

    @BLECoreActor
    func testNameFilterUsesAdvertisedLocalNameNotCachedName() async throws {
        let (client, central) = makeStarted()
        XCTAssertNotNil(central.peripheral.name, "가짜 기기는 캐시 이름을 갖는다")
        let prefix = String(central.peripheral.name!.prefix(2))
        var iterator = client.scanResults.makeAsyncIterator()
        try await client.startScan(request: request(name: prefix))

        central.deliver(AdvertisementData(localName: nil))
        central.deliver(AdvertisementData(localName: "zz-other"))
        central.deliver(AdvertisementData(localName: prefix + "-1"), rssi: 127)
        let first = await iterator.next()
        XCTAssertEqual(first?.advertisement.localName, prefix + "-1", "캐시 이름만 맞는 광고는 걸러진다")
        XCTAssertEqual(first?.rssi, 127, "RSSI 127 은 그대로 둔다")
        XCTAssertEqual(first?.peripheralID, central.peripheral.id)
        client.close()
    }

    func testMatcherIsOrAcrossItemsAndAndWithName() {
        let manufacturer = ManufacturerDataFilter(companyID: 0x0059, data: Data([0xA0]), mask: Data([0xF0]))
        let serviceData = ServiceDataFilter(serviceUUID: Self.uuidB, data: Data([1, 2]))
        let filter = ScanFilter(
            serviceUUIDs: [Self.uuidA], namePrefix: "N", manufacturerData: [manufacturer], serviceData: [serviceData]
        )
        func match(_ advertisement: AdvertisementData) -> Bool { ScanMatcher.matches(filter, advertisement) }

        XCTAssertTrue(match(AdvertisementData(localName: "Nx", serviceUUIDs: [Self.uuidA])))
        XCTAssertTrue(match(AdvertisementData(localName: "Nx", manufacturerData: [0x59: Data([0xAB])])))
        XCTAssertTrue(match(AdvertisementData(localName: "Nx", serviceData: [Self.uuidB: Data([1, 2, 3])])))
        XCTAssertFalse(match(AdvertisementData(localName: "Nx", manufacturerData: [0x59: Data([0xBB])])), "mask 를 씌운 비교")
        XCTAssertFalse(match(AdvertisementData(localName: "Nx", serviceData: [Self.uuidB: Data([1])])), "payload 가 짧다")
        XCTAssertFalse(match(AdvertisementData(localName: "Mx", serviceUUIDs: [Self.uuidA])), "이름은 AND")
        XCTAssertFalse(match(AdvertisementData(localName: nil, serviceUUIDs: [Self.uuidA])))
        XCTAssertFalse(match(AdvertisementData(localName: "Nx")), "항목이 있는데 하나도 안 맞는다")

        let nameOnly = ScanFilter(namePrefix: "N")
        XCTAssertTrue(ScanMatcher.matches(nameOnly, AdvertisementData(localName: "Nx")))
        XCTAssertTrue(ScanMatcher.matches(ScanFilter(), AdvertisementData()), "필터가 비면 모든 광고")
    }

    func testAdvertisementNormalization() {
        let normalized = AdvertisementNormalizer.normalize(
            localName: "n",
            serviceUUIDs: [BLEUUID(string: "180F")!],
            manufacturerData: Data([0x59, 0x00, 0xAA, 0xBB]),
            serviceData: [:],
            txPower: nil,
            isConnectable: true
        )
        XCTAssertEqual(normalized.manufacturerData, [0x59: Data([0xAA, 0xBB])])
        XCTAssertEqual(normalized.serviceUUIDs.map(\.string), ["0000180f-0000-1000-8000-00805f9b34fb"])
        let short = AdvertisementNormalizer.normalize(
            localName: nil, serviceUUIDs: [], manufacturerData: Data([0x59]), serviceData: [:], txPower: nil, isConnectable: nil
        )
        XCTAssertTrue(short.manufacturerData.isEmpty)
    }

    // MARK: 내부 확보 스캔

    @BLECoreActor
    func testInternalScanJoinsAndLeavesWithoutChangingPublicStateOrUserFilter() async throws {
        let (client, central) = makeStarted()
        let scanner = client.runtime.scanner
        var states = scanner.states.subscribe().makeAsyncIterator()
        var results = client.scanResults.makeAsyncIterator()
        _ = await states.next()

        try await client.startScan(request: request(services: [Self.uuidA]))
        var internalSeen = 0
        let token = scanner.acquire(services: [Self.uuidB]) { _, _, _ in internalSeen += 1 }
        XCTAssertEqual(central.scanCalls.last, .init(services: [Self.uuidA, Self.uuidB], allowDuplicates: false), "합집합")
        XCTAssertEqual(scanState(client), "Scanning")

        central.deliver(AdvertisementData(localName: "b-only", serviceUUIDs: [Self.uuidB]))
        central.deliver(AdvertisementData(localName: "a-dev", serviceUUIDs: [Self.uuidA]))
        let first = await results.next()
        XCTAssertEqual(first?.advertisement.localName, "a-dev", "사용자 필터는 유지되고 내부 스캔의 광고는 사용자 결과에 안 나온다")
        XCTAssertEqual(internalSeen, 1, "내부 스캔은 자기 서비스 광고만 받는다")

        scanner.release(token)
        XCTAssertEqual(central.scanCalls.last, .init(services: [Self.uuidA], allowDuplicates: false))
        XCTAssertEqual(scanState(client), "Scanning")
        scanner.release(token)
        XCTAssertEqual(central.scanCalls.count, 3, "release 는 멱등이다")

        // 공개 상태 흐름에는 Scanning 하나만 더 왔다
        let next = await states.next()
        XCTAssertEqual(next.map(describe), "Scanning")
        client.close()
    }

    @BLECoreActor
    func testInternalScanAloneNeverTouchesPublicState() async throws {
        let (client, central) = makeStarted()
        let scanner = client.runtime.scanner
        let token = scanner.acquire(services: []) { _, _, _ in }
        XCTAssertEqual(central.scanCalls.last, .init(services: nil, allowDuplicates: false))
        XCTAssertEqual(scanState(client), "Idle")
        XCTAssertFalse(client.runtime.snapshot().scanning)

        // 사용자가 stopScan 해도 내부 스캔은 플랫폼에 남는다
        try await client.startScan(request: request(services: [Self.uuidA], mode: .lowLatency))
        XCTAssertEqual(central.scanCalls.last, .init(services: nil, allowDuplicates: true), "서비스 조건 없는 참여자가 있으면 필터 없음")
        await client.stopScan()
        XCTAssertEqual(central.scanCalls.last, .init(services: nil, allowDuplicates: false))
        XCTAssertEqual(central.stopCalls, 0)
        scanner.release(token)
        XCTAssertEqual(central.stopCalls, 1)
        XCTAssertEqual(scanState(client), "Idle")
        client.close()
    }

    // MARK: 어댑터 이탈

    @BLECoreActor
    func testAdapterLeavingReadyEndsScanWithFailure() async throws {
        for leaving in [CentralPortState.poweredOff, .resetting, .unknown] {
            let (client, central) = makeStarted()
            try await client.startScan(request: request())
            XCTAssertEqual(scanState(client), "Scanning")
            central.setAdapter(leaving)
            XCTAssertEqual(scanState(client), "Idle(Failed:SCAN_STOPPED_BY_ADAPTER)", "\(leaving)")
            XCTAssertFalse(client.runtime.snapshot().scanning)

            // 돌아온 뒤 다시 시작할 수 있다
            central.setAdapter(.poweredOn)
            try await client.startScan(request: request())
            XCTAssertEqual(scanState(client), "Scanning")
            client.close()
        }
    }

    @BLECoreActor
    func testStopAfterFailureReturnsToIdle() async throws {
        let (client, central) = makeStarted()
        try await client.startScan(request: request())
        central.setAdapter(.poweredOff)
        await client.stopScan()
        XCTAssertEqual(scanState(client), "Idle")
        client.close()
    }

    @BLECoreActor
    func testInternalScanResumesWhenAdapterReturns() async throws {
        let (client, central) = makeStarted()
        let scanner = client.runtime.scanner
        _ = scanner.acquire(services: [Self.uuidB]) { _, _, _ in }
        let before = central.scanCalls.count
        central.setAdapter(.poweredOff)
        central.setAdapter(.poweredOn)
        XCTAssertEqual(central.scanCalls.count, before + 1)
        XCTAssertEqual(scanState(client), "Idle")
        client.close()
    }
}
