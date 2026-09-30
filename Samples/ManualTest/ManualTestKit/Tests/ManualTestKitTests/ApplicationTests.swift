import Foundation
import ManualTestApplication
import ManualTestDomain
import XCTest

@MainActor
final class ApplicationTests: XCTestCase {
    let id = DeviceId("AAAAAAAA-1111")
    var gateway: FakeGateway!
    var logStore: MemoryLogStore!
    var state: ConsoleState!

    override func setUp() async throws {
        gateway = FakeGateway()
        logStore = MemoryLogStore()
        state = ConsoleState(logStore: logStore, clock: SteppingClock())
    }

    private var texts: [String] { state.log.entries.map(\.text) }

    /// 점검 1–3: Ready → 어댑터 꺼짐 → 꺼진 채 read·connect 거절 → 켜짐 → 한 번 재연결 → 알림 재개
    func testAdapterOffAndBackScenario() async throws {
        let observe = ObserveGateway(gateway: gateway, state: state)
        await SelectDevice(state: state)(id)
        for event: GatewayEvent in [
            .adapter(.ready), .scan(.scanning),
            .link(id, .connecting), .link(id, .discoveringServices), .link(id, .configuring), .link(id, .ready),
            .activeSubscriptions(id, [.probeValue]),
            .notification(id, .probeValue, Data([0x01])),
            .adapter(.poweredOff), .link(id, .recovering(code: "LINK_FAILED")),
            .link(id, .disconnectedFailed(code: "ADAPTER_UNAVAILABLE")), .activeSubscriptions(id, []),
            .scan(.failed(code: "SCAN_STOPPED_BY_ADAPTER")),
        ] { observe.handle(event) }

        gateway.fail("read", code: "ADAPTER_UNAVAILABLE")
        gateway.fail("connect", code: "ADAPTER_UNAVAILABLE")
        await ReadValue(gateway: gateway, state: state)()
        await Connect(gateway: gateway, state: state)()
        XCTAssertEqual(state.session.link, .disconnectedFailed(code: "ADAPTER_UNAVAILABLE"), "반환 전 실패는 상태를 바꾸지 않는다")

        for event: GatewayEvent in [
            .adapter(.ready),
            .link(id, .connecting), .link(id, .discoveringServices), .link(id, .configuring), .link(id, .ready),
            .activeSubscriptions(id, [.probeValue]),
            .notification(id, .probeValue, Data([0x02])),
        ] { observe.handle(event) }

        XCTAssertEqual(texts, [
            "select 성공 AAAAAAAA-1111",
            "adapter Ready", "scan Scanning",
            "AAAAAAAA Connecting", "AAAAAAAA DiscoveringServices", "AAAAAAAA Configuring", "AAAAAAAA Ready",
            "AAAAAAAA activeSubscriptions {probe.value}",
            "AAAAAAAA probe.value #1 01",
            "adapter PoweredOff", "AAAAAAAA Recovering(LINK_FAILED)",
            "AAAAAAAA Disconnected(Failed:ADAPTER_UNAVAILABLE)", "AAAAAAAA activeSubscriptions {}",
            "scan Idle(Failed:SCAN_STOPPED_BY_ADAPTER)",
            "read 실패 ADAPTER_UNAVAILABLE fake",
            "connect 실패 ADAPTER_UNAVAILABLE fake",
            "adapter Ready",
            "AAAAAAAA Connecting", "AAAAAAAA DiscoveringServices", "AAAAAAAA Configuring", "AAAAAAAA Ready",
            "AAAAAAAA activeSubscriptions {probe.value}",
            "AAAAAAAA probe.value #2 02",
        ])
        XCTAssertEqual(state.session.link, .ready)
        XCTAssertEqual(state.session.readyCount, 2)
        XCTAssertEqual(state.session.activeSubscriptions, [.probeValue])
        XCTAssertEqual(state.session.notifications.count, 2)
        XCTAssertEqual(state.adapter, .ready)
        XCTAssertEqual(state.scan, .failed(code: "SCAN_STOPPED_BY_ADAPTER"))
        XCTAssertEqual(logStore.saved.map(\.text), texts, "모든 줄이 저장소에 쓰인다")
        XCTAssertEqual(gateway.calls, ["read probe.value", "connect AAAAAAAA-1111 auto=true"])
    }

    func testRunConsumesStreamUntilFinished() async {
        let observe = ObserveGateway(gateway: gateway, state: state)
        gateway.emit(.adapter(.poweredOff))
        gateway.emit(.diagnostic(code: "PERIPHERAL_NOT_FOUND", message: "x"))
        gateway.finish()
        await observe.run()
        XCTAssertEqual(texts, ["adapter PoweredOff", "진단 PERIPHERAL_NOT_FOUND x"])
    }

    func testCommandsWithoutDeviceAreRecordedAsDomainFailure() async {
        await Connect(gateway: gateway, state: state)()
        await Subscribe(gateway: gateway, state: state)()
        XCTAssertEqual(texts, ["connect 실패 NO_DEVICE_SELECTED noDeviceSelected", "subscribe 실패 NO_DEVICE_SELECTED noDeviceSelected"])
        XCTAssertTrue(gateway.calls.isEmpty)
    }

    func testAutoReconnectOffIsPassedToConnect() async {
        await SelectDevice(state: state)(id)
        await SetAutoReconnect(state: state)(false)
        await Connect(gateway: gateway, state: state)()
        await WriteNus(gateway: gateway, state: state)("hi")
        XCTAssertEqual(gateway.calls, ["connect AAAAAAAA-1111 auto=false", "write nus.rx 6869"])
        XCTAssertEqual(texts.last, "write 성공 nus.rx 2B \"hi\"")
    }

    func testPolicyChangeRejectedWhileConnected() async {
        await SelectDevice(state: state)(id)
        ObserveGateway(gateway: gateway, state: state).handle(.link(id, .ready))
        await SetAutoReconnect(state: state)(false)
        XCTAssertTrue(state.session.autoReconnect)
        XCTAssertEqual(texts.last, "setAutoReconnect 실패 SESSION_ACTIVE sessionActive(ManualTestDomain.LinkState.ready)")
    }

    /// 점검 8: 백그라운드 재실행이면 사유를 남기고, 저장된 등록으로 시작하고, 복원된 세션을 snapshot 으로 남긴다
    func testRecordLaunchUsesStoredRegistrationAndLogsSnapshots() async {
        let registration = DeviceRegistration(deviceId: id, autoReconnect: true, subscribe: [.probeValue])
        gateway.setSnapshot(GatewaySnapshot(
            adapter: .ready, scanning: false,
            sessions: [ObservedSession(id: id, link: .ready, subscriptions: [.probeValue])]
        ))
        let launch = RecordLaunch(
            gateway: gateway, state: state, registrationStore: MemoryRegistrationStore(registration), settleDelay: .zero
        )
        await launch(LaunchContext(
            launchedInBackground: true, appState: "background", protectedDataAvailable: true, hasBluetoothCentralsKey: false
        )).value

        XCTAssertEqual(gateway.startedWith, .some(registration))
        XCTAssertEqual(state.session.deviceId, id)
        XCTAssertEqual(state.activeRegistration, registration)
        XCTAssertEqual(texts, [
            "실행: 블루투스 복원 재실행(백그라운드) appState=background protectedData=true bluetoothCentralsKey=false 등록=AAAAAAAA auto=true sub={probe.value}",
            "snapshot(start 직후): adapter=Ready scanning=false sessions=[AAAAAAAA Ready sub={probe.value}]",
            "snapshot(start+0s): adapter=Ready scanning=false sessions=[AAAAAAAA Ready sub={probe.value}]",
        ])
        XCTAssertTrue(state.log.entries.allSatisfy { $0.kind == .launch })
    }

    func testSaveAndClearRegistration() async {
        let store = MemoryRegistrationStore()
        await SelectDevice(state: state)(id)
        await SetAutoReconnect(state: state)(false)
        await SaveRegistration(state: state, store: store)()
        XCTAssertEqual(try store.load(), DeviceRegistration(deviceId: id, autoReconnect: false, subscribe: [.probeValue]))
        XCTAssertEqual(state.registration?.autoReconnect, false)
        XCTAssertNil(state.activeRegistration, "이번 실행 등록은 바뀌지 않는다")
        await ClearRegistration(state: state, store: store)()
        XCTAssertNil(try store.load())
    }

    func testRestoredLogContinuesAfterRelaunch() {
        let observe = ObserveGateway(gateway: gateway, state: state)
        observe.handle(.adapter(.ready))
        let relaunched = ConsoleState(logStore: logStore, clock: SteppingClock())
        ObserveGateway(gateway: gateway, state: relaunched).handle(.adapter(.poweredOff))
        XCTAssertEqual(relaunched.log.entries.map(\.seq), [1, 2])
        XCTAssertEqual(relaunched.log.entries.map(\.launch), [1, 2])
    }
}
