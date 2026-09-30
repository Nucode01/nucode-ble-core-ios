import Foundation
import ManualTestDomain
import XCTest

final class DomainTests: XCTestCase {
    let a = DeviceId("AAAAAAAA-0000")
    let b = DeviceId("BBBBBBBB-0000")

    func testSelectAndPolicyAreLockedWhileLinkIsActive() throws {
        var session = TestSession()
        try session.select(a)
        session.apply(link: .connecting, of: a)
        XCTAssertThrowsError(try session.select(b)) { XCTAssertEqual($0 as? DomainError, .sessionActive(.connecting)) }
        XCTAssertThrowsError(try session.setAutoReconnect(false))
        session.apply(link: .disconnectedFailed(code: "ADAPTER_UNAVAILABLE"), of: a)
        try session.setAutoReconnect(false)
        try session.select(b)
        XCTAssertEqual(session.deviceId, b)
        XCTAssertEqual(session.link, .disconnectedInitial)
    }

    func testRequireDeviceWithoutSelection() {
        XCTAssertThrowsError(try TestSession().requireDevice()) { XCTAssertEqual($0 as? DomainError, .noDeviceSelected) }
    }

    func testOtherDeviceEventsDoNotChangeSession() throws {
        var session = TestSession()
        try session.select(a)
        XCTAssertFalse(session.apply(link: .ready, of: b))
        XCTAssertFalse(session.recordNotification(Data([1]), of: b, at: Date()))
        XCTAssertFalse(session.apply(activeSubscriptions: [.probeValue], of: b))
        XCTAssertEqual(session.link, .disconnectedInitial)
        XCTAssertEqual(session.notifications.count, 0)
        XCTAssertTrue(session.activeSubscriptions.isEmpty)
    }

    func testReadyCountAndNotificationStats() throws {
        var session = TestSession()
        try session.select(a)
        session.apply(link: .ready, of: a)
        session.apply(link: .recovering(code: "LINK_FAILED"), of: a)
        session.apply(link: .ready, of: a)
        let at = Date(timeIntervalSince1970: 10)
        session.recordNotification(Data([0xab]), of: a, at: at)
        XCTAssertEqual(session.readyCount, 2)
        XCTAssertEqual(session.notifications.count, 1)
        XCTAssertEqual(session.notifications.lastAt, at)
        XCTAssertEqual(session.notifications.lastValue, Data([0xab]))
    }

    func testLinkLabelsFollowContractNotation() {
        XCTAssertEqual(LinkState.disconnectedFailed(code: "ADAPTER_UNAVAILABLE").label, "Disconnected(Failed:ADAPTER_UNAVAILABLE)")
        XCTAssertEqual(LinkState.recovering(code: "LINK_FAILED").label, "Recovering(LINK_FAILED)")
        XCTAssertEqual(ScanStatus.failed(code: "SCAN_STOPPED_BY_ADAPTER").label, "Idle(Failed:SCAN_STOPPED_BY_ADAPTER)")
    }

    func testEventLogContinuesSeqAndCountsLaunches() {
        var first = EventLog()
        XCTAssertEqual(first.launch, 1)
        first.append(.adapterChanged(.ready), at: Date())
        first.append(.adapterChanged(.poweredOff), at: Date())
        var second = EventLog(restoring: first.entries)
        XCTAssertEqual(second.launch, 2)
        let entry = second.append(.scanChanged(.idle), at: Date())
        XCTAssertEqual(entry.seq, 3)
        XCTAssertEqual(entry.launch, 2)
        XCTAssertEqual(entry.kind, .scan)
    }

    func testChecklistRejectsUnknownItem() throws {
        var checklist = Checklist()
        XCTAssertEqual(Checklist.items.map(\.id), Array(1...9))
        try checklist.mark(3, verdict: .pass, note: "ok", at: Date())
        XCTAssertEqual(checklist.result(for: 3).verdict, .pass)
        XCTAssertEqual(checklist.result(for: 4).verdict, .pending)
        XCTAssertThrowsError(try checklist.mark(10, verdict: .fail, note: "", at: Date())) {
            XCTAssertEqual($0 as? DomainError, .unknownChecklistItem(10))
        }
    }

    func testProbeCharacteristicLookup() {
        XCTAssertEqual(
            ProbeCharacteristic(serviceUUID: "6E7A0001-5C3A-4B8E-9D1F-0A1B2C3D4E5F", uuid: "6E7A0002-5C3A-4B8E-9D1F-0A1B2C3D4E5F"),
            .probeValue
        )
        XCTAssertNil(ProbeCharacteristic(serviceUUID: ProbeProfile.nusServiceUUID, uuid: ProbeCharacteristic.probeValue.uuid))
    }

    func testLaunchReason() {
        XCTAssertEqual(LaunchReason.classify(launchedInBackground: true), .bluetoothRelaunch)
        XCTAssertEqual(LaunchReason.classify(launchedInBackground: false), .userLaunch)
    }
}
