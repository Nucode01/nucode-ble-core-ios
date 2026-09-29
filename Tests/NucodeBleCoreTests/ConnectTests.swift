import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// 가짜 central 을 감싸 확보 경로와 connect 전달을 시험이 정한다.
/// - `knowsPeripheral`: `retrievePeripherals` 가 기기를 준다
/// - `forwardsScan`: 스캔을 가짜 central 에 넘긴다(끄면 광고가 없다)
/// - `forwardsConnect`: connect 를 가짜 기기에 넘긴다(끄면 OS 가 계속 기다린다)
@BLECoreActor
private final class ConnectCentral: CentralPort {
    let inner: FakeCentral
    var knowsPeripheral = false
    var forwardsScan = true
    var forwardsConnect = false
    private(set) var connectCalls = 0
    private(set) var cancelCalls = 0
    private(set) var scanCalls = 0
    private(set) var stopCalls = 0
    private(set) var retrieveCalls = 0

    weak var delegate: (any CentralPortDelegate)? {
        didSet { inner.delegate = delegate }
    }

    init(inner: FakeCentral) { self.inner = inner }

    var state: CentralPortState { inner.state }
    var authorization: PortAuthorization { inner.authorization }
    var peripheral: FakePeripheral { inner.peripheral }

    func scanForPeripherals(services: [BLEUUID]?, allowDuplicates: Bool) {
        scanCalls += 1
        if forwardsScan { inner.scanForPeripherals(services: services, allowDuplicates: allowDuplicates) }
    }

    func stopScan() {
        stopCalls += 1
        inner.stopScan()
    }

    func retrievePeripherals(withIdentifiers identifiers: [PeripheralID]) -> [any PeripheralPort] {
        retrieveCalls += 1
        return knowsPeripheral ? [inner.peripheral] : inner.retrievePeripherals(withIdentifiers: identifiers)
    }

    func retrieveConnectedPeripherals(withServices services: [BLEUUID]) -> [any PeripheralPort] {
        inner.retrieveConnectedPeripherals(withServices: services)
    }

    func connect(_ peripheral: any PeripheralPort) {
        connectCalls += 1
        if forwardsConnect { inner.connect(peripheral) }
    }

    func cancelPeripheralConnection(_ peripheral: any PeripheralPort) {
        cancelCalls += 1
        inner.cancelPeripheralConnection(peripheral)
    }
}

/// 성공은 "ok", 실패는 실패 코드
private func connectOutcome(_ client: BLEClient, _ options: ConnectOptions) async -> String {
    do {
        _ = try await client.connect(FakeDeviceSpec.defaultID, options: options)
        return "ok"
    } catch let error as BLEError {
        return error.failure.code.value
    } catch is CancellationError {
        return "cancelled"
    } catch {
        return "other"
    }
}

@BLECoreActor
final class ConnectTests: XCTestCase {
    typealias Support = ClientTestSupport

    private let id = FakeDeviceSpec.defaultID

    private func makeStarted(
        known: Bool = true,
        forwardsScan: Bool = true,
        forwardsConnect: Bool = false,
        state: CentralPortState = .poweredOn
    ) -> (BLEClient, ConnectCentral) {
        let inner = Support.makeCentral(state: state)
        let central = ConnectCentral(inner: inner)
        central.knowsPeripheral = known
        central.forwardsScan = forwardsScan
        central.forwardsConnect = forwardsConnect
        let client = Support.makeClient { central }
        client.start()
        return (client, central)
    }

    private func session(_ client: BLEClient) -> Session { client.runtime.registry.session(for: id) }

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

    private func stateName(_ client: BLEClient) -> String { describe(session(client).state.value) }

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    // MARK: 기기 확보 실패

    /// coverage connection.auto-reconnect 의 iOS 몫: 본 적 없는 ID 에는 대기 connect 를 걸 수 없다
    func testUnknownIDWithAutoReconnectThrowsNotFoundAndKeepsState() async throws {
        let (client, central) = await makeStarted(known: false, forwardsScan: false)
        let events = client.events
        let result = await connectOutcome(client, ConnectOptions(autoReconnect: true))
        XCTAssertEqual(result, "PERIPHERAL_NOT_FOUND")
        let (name, connects, scanning) = await (stateName(client), central.connectCalls, client.snapshot().scanning)
        XCTAssertEqual(name, "Disconnected(Initial)")
        XCTAssertEqual(connects, 0)
        XCTAssertFalse(scanning)
        // 확보 스캔은 끝났고 연결 이벤트는 없다
        let scanStopped = await central.stopCalls
        XCTAssertGreaterThan(scanStopped, 0)
        client.close()
        var seen: [String] = []
        for await event in events { if case .connection = event { seen.append("connection") } }
        XCTAssertEqual(seen, [])
    }

    func testUnknownIDWithoutAutoReconnectThrowsNotFound() async throws {
        let (client, _) = await makeStarted(known: false, forwardsScan: false)
        let result = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(result, "PERIPHERAL_NOT_FOUND")
        let name = await stateName(client)
        XCTAssertEqual(name, "Disconnected(Initial)")
    }

    // MARK: 기기 확보 성공

    func testKnownPeripheralConnectsWithoutScanAndReturnsOnceRequested() async throws {
        let (client, central) = await makeStarted()
        let result = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(result, "ok")
        let (name, connects, scans) = await (stateName(client), central.connectCalls, central.scanCalls)
        XCTAssertEqual(name, "Connecting")
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(scans, 0)
    }

    func testResolvesByAcquisitionScanWithoutChangingPublicScanState() async throws {
        let (client, central) = await makeStarted(known: false)
        let states = client.scanStates
        let result = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(result, "ok")
        let (name, connects, scanning) = await (stateName(client), central.connectCalls, client.snapshot().scanning)
        XCTAssertEqual(name, "Connecting")
        XCTAssertEqual(connects, 1)
        XCTAssertFalse(scanning)
        client.close()
        var scanStates: [String] = []
        for await state in states { if case .idle = state { scanStates.append("Idle") } else { scanStates.append("other") } }
        XCTAssertEqual(scanStates, ["Idle"])
    }

    func testConnectEmitsConnectionEventAndStateFlow() async throws {
        let (client, _) = await makeStarted()
        let session = try client.session(for: id)
        let states = session.connectionStates
        let events = client.events
        _ = await connectOutcome(client, ConnectOptions())
        client.close()
        var eventNames: [String] = []
        for await event in events { if case .connection(_, let state) = event { eventNames.append(describe(state)) } }
        XCTAssertEqual(eventNames, ["Connecting"])
        var stateNames: [String] = []
        for await state in states { stateNames.append(describe(state)) }
        XCTAssertEqual(stateNames, ["Disconnected(Initial)", "Connecting"])
    }

    // MARK: 진입 판정

    func testClosedClientFailsWithClientClosed() async throws {
        let (client, _) = await makeStarted()
        let session = try client.session(for: id)
        client.close()
        do {
            try await session.connect(options: ConnectOptions())
            XCTFail("throws")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code.value, "CLIENT_CLOSED")
        }
        let viaClient = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(viaClient, "CLIENT_CLOSED")
    }

    func testConflictingOptionsFailAndSameOptionsJoinImmediately() async throws {
        let (client, central) = await makeStarted()
        let first = await connectOutcome(client, ConnectOptions(autoReconnect: false))
        XCTAssertEqual(first, "ok")
        let conflict = await connectOutcome(client, ConnectOptions(autoReconnect: true))
        XCTAssertEqual(conflict, "CONNECTION_OPTIONS_CONFLICT")
        let joined = await connectOutcome(client, ConnectOptions(autoReconnect: false))
        XCTAssertEqual(joined, "ok")
        let (connects, name) = await (central.connectCalls, stateName(client))
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(name, "Connecting")
    }

    func testConcurrentConnectsShareOneAttemptAndOptionsConflictDuringStart() async throws {
        let (client, central) = await makeStarted(known: false)
        async let first = connectOutcome(client, ConnectOptions())
        try await Task.sleep(for: .milliseconds(1))
        async let joined = connectOutcome(client, ConnectOptions())
        async let conflict = connectOutcome(client, ConnectOptions(autoReconnect: true))
        let results = await [first, joined, conflict]
        XCTAssertEqual(results.filter { $0 == "ok" }.count, 2)
        XCTAssertEqual(results.filter { $0 == "CONNECTION_OPTIONS_CONFLICT" }.count, 1)
        let connects = await central.connectCalls
        XCTAssertEqual(connects, 1)
    }

    func testConnectDuringDisconnectingFails() async throws {
        let (client, central) = await makeStarted()
        self.session(client).state.send(.disconnecting)
        let result = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(result, "CONNECT_DURING_DISCONNECT")
        let connects = await central.connectCalls
        XCTAssertEqual(connects, 0)
    }

    func testAdapterOffFailsBeforeStateChange() async throws {
        let (client, central) = await makeStarted(state: .poweredOff)
        let result = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(result, "ADAPTER_UNAVAILABLE")
        let (name, connects) = await (stateName(client), central.connectCalls)
        XCTAssertEqual(name, "Disconnected(Initial)")
        XCTAssertEqual(connects, 0)
    }

    // MARK: 호출자 취소

    func testCancelBeforeReturnCleansUpAttempt() async throws {
        let (client, central) = await makeStarted(known: false, forwardsScan: false)
        let session = try client.session(for: id)
        let task = Task { try await session.connect(options: ConnectOptions()) }
        let scanning = await waitUntil { central.scanCalls > 0 }
        XCTAssertTrue(scanning)
        task.cancel()
        do {
            try await task.value
            XCTFail("cancelled")
        } catch is CancellationError {}
        let (name, connects, stops) = await (stateName(client), central.connectCalls, central.stopCalls)
        XCTAssertEqual(name, "Disconnected(Initial)")
        XCTAssertEqual(connects, 0)
        XCTAssertGreaterThan(stops, 0)
        // 정리된 뒤에는 새 시도가 받아들여진다
        central.knowsPeripheral = true
        let again = await connectOutcome(client, ConnectOptions())
        XCTAssertEqual(again, "ok")
    }

    func testCloseDuringAcquisitionFailsWithClientClosed() async throws {
        let (client, central) = await makeStarted(known: false, forwardsScan: false)
        let session = try client.session(for: id)
        let task = Task { try await session.connect(options: ConnectOptions()) }
        let scanning = await waitUntil { central.scanCalls > 0 }
        XCTAssertTrue(scanning)
        client.close()
        do {
            try await task.value
            XCTFail("closed")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code.value, "CLIENT_CLOSED")
        }
    }

    // MARK: 링크 실패와 기한

    func testDidFailToConnectEndsWithLinkFailed() async throws {
        let (client, central) = await makeStarted()
        _ = await connectOutcome(client, ConnectOptions())
        client.runtime.central(central, didFailToConnect: central.peripheral, error: PortError(domain: "CBErrorDomain", code: 14, message: "fail"))
        let name = await stateName(client)
        XCTAssertEqual(name, "Disconnected(Failed:LINK_FAILED)")
        // 실패로 끝난 뒤에는 새 시도가 받아들여진다(새 generation)
        let (generation, again) = await (session(client).generation, connectOutcome(client, ConnectOptions()))
        XCTAssertEqual(again, "ok")
        let next = await session(client).generation
        XCTAssertEqual(next, generation + 1)
    }

    func testLinkDeadlineWithoutAutoReconnectEndsWithLinkTimeout() async throws {
        let (client, central) = await makeStarted()
        _ = await connectOutcome(client, ConnectOptions())
        let name0 = await stateName(client)
        XCTAssertEqual(name0, "Connecting")
        let reached = await waitUntil(realMilliseconds: Support.realMilliseconds(Deadlines.link) + 1500) {
            self.describe(self.session(client).state.value) == "Disconnected(Failed:LINK_TIMEOUT)"
        }
        XCTAssertTrue(reached)
        let cancels = await central.cancelCalls
        XCTAssertEqual(cancels, 1)
    }

    func testAutoReconnectHasNoLinkDeadline() async throws {
        let (client, _) = await makeStarted()
        _ = await connectOutcome(client, ConnectOptions(autoReconnect: true))
        await Support.sleep(realMilliseconds: Support.realMilliseconds(Deadlines.link) + 300)
        let name = await stateName(client)
        XCTAssertEqual(name, "Connecting")
    }

    // MARK: central 콜백 걸러내기

    func testStaleAndForeignCentralCallbacksAreIgnored() async throws {
        let (client, central) = await makeStarted()
        _ = await connectOutcome(client, ConnectOptions())
        // 다른 기기 객체의 콜백은 무시한다
        let foreign = Support.makeCentral().peripheral
        client.runtime.central(central, didFailToConnect: foreign, error: nil)
        client.runtime.central(central, didConnect: foreign)
        let name1 = await stateName(client)
        XCTAssertEqual(name1, "Connecting")
        // 기한이 지나 끝난 시도(오래된 generation)의 늦은 콜백은 무시한다
        let ended = await waitUntil(realMilliseconds: Support.realMilliseconds(Deadlines.link) + 1500) {
            self.describe(self.session(client).state.value) == "Disconnected(Failed:LINK_TIMEOUT)"
        }
        XCTAssertTrue(ended)
        client.runtime.central(central, didFailToConnect: central.peripheral, error: nil)
        client.runtime.central(central, didConnect: central.peripheral)
        let name2 = await stateName(client)
        XCTAssertEqual(name2, "Disconnected(Failed:LINK_TIMEOUT)")
    }
}

