import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// core 큐의 다음 차례에 실행한다(콜백은 core 큐에서 온다)
@BLECoreActor
private func fakeEmit<Owner: AnyObject & Sendable>(_ owner: Owner, _ body: @escaping @BLECoreActor (Owner) -> Void) {
    bleCoreQueue.async { [weak owner] in
        BLECoreActor.assumeIsolated { if let owner { body(owner) } }
    }
}

/// 서비스 탐색 결과와 콜백 누락을 시험이 정하는 central·peripheral 한 쌍. 링크는 즉시 붙는다.
@BLECoreActor
private final class ScriptedCentral: CentralPort {
    let peripheral: ScriptedPeripheral
    var state: CentralPortState { .poweredOn }
    var authorization: PortAuthorization { .allowedAlways }
    weak var delegate: (any CentralPortDelegate)?
    /// 끄면 `cancelPeripheralConnection` 뒤에도 `didDisconnect` 가 오지 않는다
    var deliversDisconnect = true
    private(set) var cancelCalls = 0

    init(peripheral: ScriptedPeripheral) {
        self.peripheral = peripheral
        peripheral.central = self
    }

    func scanForPeripherals(services: [BLEUUID]?, allowDuplicates: Bool) {}
    func stopScan() {}
    func retrievePeripherals(withIdentifiers identifiers: [PeripheralID]) -> [any PeripheralPort] { [peripheral] }
    func retrieveConnectedPeripherals(withServices services: [BLEUUID]) -> [any PeripheralPort] { [] }

    func connect(_ peripheral: any PeripheralPort) {
        self.peripheral.linked = true
        fakeEmit(self) { $0.delegate?.central($0, didConnect: $0.peripheral) }
    }

    func cancelPeripheralConnection(_ peripheral: any PeripheralPort) {
        cancelCalls += 1
        guard deliversDisconnect, self.peripheral.linked else { return }
        self.peripheral.linked = false
        fakeEmit(self) { $0.delegate?.central($0, didDisconnect: $0.peripheral, error: nil) }
    }
}

@BLECoreActor
private final class ScriptedPeripheral: PeripheralPort {
    let id = FakeDeviceSpec.defaultID
    var name: String? { "scripted" }
    var connectionState: PortPeripheralState { linked ? .connected : .disconnected }
    weak var delegate: (any PeripheralPortDelegate)?
    weak var central: ScriptedCentral?
    var canSendWriteWithoutResponse: Bool { true }
    var linked = false

    var services: [NucodeBleCore.ServiceRef] = []
    var characteristics: [CharacteristicRef] = []
    var serviceError: PortError?
    var answersDiscovery = true
    private(set) var discoverArguments: [[BLEUUID]?] = []

    func discoverServices(_ serviceUUIDs: [BLEUUID]?) {
        discoverArguments.append(serviceUUIDs)
        guard answersDiscovery else { return }
        fakeEmit(self) { $0.delegate?.peripheral($0, didDiscoverServices: $0.services, error: $0.serviceError) }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [BLEUUID]?, for service: NucodeBleCore.ServiceRef) {
        fakeEmit(self) { device in
            let mine = device.characteristics.filter { $0.service == service }
            device.delegate?.peripheral(device, didDiscoverCharacteristics: mine, for: service, error: nil)
        }
    }

    func readValue(for characteristic: CharacteristicRef) {}
    func writeValue(_ data: Data, for characteristic: CharacteristicRef, type: WriteMode) {}
    func maximumWriteValueLength(for type: WriteMode) -> Int { 20 }
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRef) {}
}

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

@BLECoreActor
final class LinkSetupTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID
    private let serviceUUID = BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!
    private let characteristicUUID = BLEUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")!

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private func stateName(_ session: Session) -> String { describe(session.state.value) }

    private func scripted(characteristicCount: Int = 2) -> ScriptedCentral {
        let peripheral = ScriptedPeripheral()
        let service = NucodeBleCore.ServiceRef(uuid: serviceUUID, instanceIndex: 0)
        peripheral.services = [service]
        peripheral.characteristics = (0..<characteristicCount).map { _ in
            CharacteristicRef(service: service, uuid: characteristicUUID, instanceIndex: 0)
        }
        return ScriptedCentral(peripheral: peripheral)
    }

    private func start(_ central: any CentralPort) -> (DefaultBLEClient, Session) {
        let client = Support.makeClient { central }
        client.start()
        return (client, client.runtime.registry.session(for: id))
    }

    // MARK: 가짜 기기(프로브 정의) 전체 경로

    func testFullPathTransitionsAndServicesSurviveDisconnect() async throws {
        let dir = ContractDirectory.locate(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        // 처음 보는 기기라 확보 스캔으로 찾는다
        let (client, session) = start(central)
        let handle = try client.session(for: id)
        let states = handle.connectionStates
        let services = handle.services
        let subscriptions = handle.activeSubscriptions
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { if case .ready = session.state.value { return true } else { return false } }
        XCTAssertTrue(ready)
        await handle.disconnect()
        XCTAssertEqual(stateName(session), "Disconnected(Requested)")
        XCTAssertFalse(session.services.isEmpty, "해제 뒤에도 서비스 목록이 남는다")
        client.close()
        var names: [String] = []
        for await state in states { names.append(describe(state)) }
        XCTAssertEqual(names.filter { $0 != "Disconnected(Initial)" }.prefix(6).map { $0 },
                       ["Connecting", "DiscoveringServices", "Configuring", "Ready", "Disconnecting", "Disconnected(Requested)"])
        var lists: [[GATTService]] = []
        for await list in services { lists.append(list) }
        XCTAssertEqual(lists.first?.isEmpty, true)
        XCTAssertEqual(lists.last?.isEmpty, false)
        var sets: [Set<CharacteristicRef>] = []
        for await set in subscriptions { sets.append(set) }
        XCTAssertTrue(sets.allSatisfy(\.isEmpty))
    }

    // MARK: instanceIndex 와 진단

    func testSameUUIDCharacteristicsGetInstanceIndexZeroAndOneWithDiagnostic() async throws {
        let central = scripted()
        let (client, session) = start(central)
        let events = client.events
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { if case .ready = session.state.value { return true } else { return false } }
        XCTAssertTrue(ready)
        XCTAssertEqual(central.peripheral.discoverArguments.count, 1)
        XCTAssertNil(central.peripheral.discoverArguments[0], "서비스를 고르지 않는다")
        let indexes = session.services.first?.characteristics.map(\.ref.instanceIndex)
        XCTAssertEqual(indexes, [0, 1])
        client.close()
        var diagnostics: [String] = []
        for await event in events { if case .diagnostic(let code, _) = event { diagnostics.append(code.value) } }
        XCTAssertEqual(diagnostics, ["DUPLICATE_CHARACTERISTIC_REFERENCE"])
    }

    // MARK: 탐색 실패

    func testZeroServicesFailsDiscovery() async throws {
        let central = scripted()
        central.peripheral.services = []
        let (client, session) = start(central)
        _ = try await client.connect(id, options: ConnectOptions())
        let failed = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertTrue(failed)
        XCTAssertEqual(stateName(session), "Disconnected(Failed:SERVICE_DISCOVERY_FAILED)")
        XCTAssertGreaterThan(central.cancelCalls, 0)
    }

    func testDiscoveryErrorFailsDiscovery() async throws {
        let central = scripted()
        central.peripheral.serviceError = PortError(domain: "CBErrorDomain", code: 3, message: "x")
        let (client, session) = start(central)
        _ = try await client.connect(id, options: ConnectOptions())
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertEqual(stateName(session), "Disconnected(Failed:SERVICE_DISCOVERY_FAILED)")
    }

    func testDiscoveryDeadline() async throws {
        let central = scripted()
        central.peripheral.answersDiscovery = false
        let (client, session) = start(central)
        _ = try await client.connect(id, options: ConnectOptions())
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertEqual(stateName(session), "Disconnected(Failed:SERVICE_DISCOVERY_TIMEOUT)")
    }

    func testConfigurationDeadline() async throws {
        let central = scripted()
        let (client, session) = start(central)
        session.configurationStep = { _ in }
        _ = try await client.connect(id, options: ConnectOptions())
        let stuck = await waitUntil { if case .configuring = session.state.value { return true } else { return false } }
        XCTAssertTrue(stuck)
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        XCTAssertEqual(stateName(session), "Disconnected(Failed:CONFIGURATION_TIMEOUT)")
    }

    // MARK: disconnect

    func testDisconnectIsIdempotentAndForcesEndWithoutCallback() async throws {
        let central = scripted()
        central.deliversDisconnect = false
        let (client, session) = start(central)
        let events = client.events
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { if case .ready = session.state.value { return true } else { return false } }
        XCTAssertTrue(ready)
        async let first: Void = session.disconnect()
        async let second: Void = session.disconnect()
        _ = await (first, second)
        XCTAssertEqual(stateName(session), "Disconnected(Requested)")
        await session.disconnect()
        XCTAssertEqual(stateName(session), "Disconnected(Requested)")
        client.close()
        var diagnostics: [String] = []
        for await event in events { if case .diagnostic(let code, _) = event { diagnostics.append(code.value) } }
        XCTAssertTrue(diagnostics.contains("DISCONNECT_CLEANUP_TIMEOUT"))
    }

    func testDisconnectBeforeAnyConnectIsNoOp() async throws {
        let central = scripted()
        let (_, session) = start(central)
        await session.disconnect()
        XCTAssertEqual(stateName(session), "Disconnected(Initial)")
    }

    func testStalePeripheralCallbackIsIgnored() async throws {
        let central = scripted()
        let (client, session) = start(central)
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { if case .ready = session.state.value { return true } else { return false } }
        XCTAssertTrue(ready)
        // 링크가 끝난 뒤 늦게 온 탐색 콜백은 상태를 바꾸지 않는다
        await session.disconnect()
        central.peripheral.delegate?.peripheral(central.peripheral, didDiscoverServices: [], error: nil)
        XCTAssertEqual(stateName(session), "Disconnected(Requested)")
    }
}
