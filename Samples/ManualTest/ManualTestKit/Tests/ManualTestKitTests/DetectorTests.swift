import Foundation
import ManualTestDomain
import XCTest

/// 기록을 손으로 짠다. 줄마다 0.1초씩 간다
struct Script {
    let id = DeviceId("AAAAAAAA-1111")
    let armedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var log = EventLog()
    private(set) var t: Date

    init() { t = armedAt }

    var entries: [LogEntry] { log.entries }

    /// dt 초 뒤에 한 줄
    @discardableResult
    mutating func add(_ event: DomainEvent, after dt: TimeInterval = 0.1) -> LogEntry {
        t = t.addingTimeInterval(dt)
        return log.append(event, at: t)
    }

    mutating func adds(_ events: [DomainEvent]) { events.forEach { add($0) } }

    mutating func link(_ s: LinkState, after dt: TimeInterval = 0.1) { add(.linkChanged(id, s), after: dt) }
    mutating func adapter(_ s: AdapterStatus, from previous: AdapterStatus, after dt: TimeInterval = 0.1) {
        add(.adapterChanged(s, previous: previous), after: dt)
    }

    mutating func command(_ command: Command, adapter: AdapterStatus, link: LinkState = .disconnectedFailed(code: "ADAPTER_UNAVAILABLE"),
                          failure: String?, after dt: TimeInterval = 0.1) {
        let context = CommandContext(device: id, startedAt: t.addingTimeInterval(dt / 2), adapter: adapter, link: link)
        if let failure {
            add(.commandFailed(command, code: failure, message: "x", context: context), after: dt)
        } else {
            add(.commandSucceeded(command, detail: "", context: context), after: dt)
        }
    }

    /// 새 실행(프로세스). uptime·사유·등록을 싣는다
    mutating func relaunch(_ reason: LaunchReason, uptime: TimeInterval?, registration: DeviceId? = nil, after dt: TimeInterval = 5) {
        log = EventLog(restoring: log.entries)
        let reg = registration.map { DeviceRegistration(deviceId: $0, autoReconnect: true, subscribe: [.probeValue]) }
        add(.launched(LaunchRecord(
            reason: reason, appState: reason == .userLaunch ? "inactive" : "background", protectedDataAvailable: true,
            hasBluetoothCentralsKey: false, registration: reg, systemUptime: uptime, adapter: .unknown
        )), after: dt)
    }

    func judge(_ item: Int, _ context: ArmContext, at now: Date? = nil) -> ChecklistVerdict {
        ChecklistDetectors.evaluate(item, armedAt: armedAt, entries: entries, now: now ?? t, context: context)
    }

    func judge(_ item: Int, _ context: ArmContext, after seconds: TimeInterval) -> ChecklistVerdict {
        judge(item, context, at: armedAt.addingTimeInterval(seconds))
    }
}

func context(_ link: LinkState, adapter: AdapterStatus = .ready, auto: Bool = true, scanning: Bool = false) -> ArmContext {
    ArmContext(deviceId: DeviceId("AAAAAAAA-1111"), autoReconnect: auto, link: link, adapter: adapter, scanning: scanning)
}

let offFinal = LinkState.disconnectedFailed(code: "ADAPTER_UNAVAILABLE")
let linkFailed = LinkState.recovering(code: "LINK_FAILED")

extension ChecklistVerdict {
    var isPass: Bool { if case .pass = outcome { true } else { false } }
    var isPending: Bool { if case .pending = outcome { true } else { false } }
    var failReason: String? { if case let .fail(r) = outcome { r } else { nil } }
    var humanNote: String? { if case let .needsHuman(n) = outcome { n } else { nil } }
}

final class DetectorTests: XCTestCase {
    // MARK: 1

    func testItem1PassWithInterimRecoveringAndScanStop() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(linkFailed)
        s.link(offFinal)
        s.add(.scanChanged(.failed(code: "SCAN_STOPPED_BY_ADAPTER")))
        let v = s.judge(1, context(.ready, scanning: true))
        XCTAssertTrue(v.isPass, "\(v)")
        XCTAssertEqual(v.evidence, s.entries.map(\.seq))
    }

    func testItem1PassWhenLinkLineComesBeforeAdapterLine() {
        var s = Script()
        s.link(linkFailed)
        s.adapter(.poweredOff, from: .ready)
        s.link(offFinal)
        XCTAssertTrue(s.judge(1, context(.ready)).isPass)
    }

    func testItem1FailsOnExtraState() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(linkFailed)
        s.link(.connecting)
        XCTAssertEqual(s.judge(1, context(.ready)).failReason, "예상 밖 상태 Connecting")
    }

    func testItem1FailsWhenLinkLeftReadyOtherwiseJustBeforeAdapterOff() {
        var s = Script()
        s.link(.disconnectedFailed(code: "LINK_FAILED"))
        s.adapter(.poweredOff, from: .ready)
        XCTAssertEqual(s.judge(1, context(.ready)).failReason, "예상 밖 상태 Disconnected(Failed:LINK_FAILED)")
    }

    func testItem1FailsOnRecoveringWithAutoReconnectOff() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(linkFailed)
        XCTAssertEqual(s.judge(1, context(.ready, auto: false)).failReason, "예상 밖 상태 Recovering(LINK_FAILED)")
    }

    func testItem1FailsWhenScanEndsWithoutAdapterCode() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.add(.scanChanged(.idle))
        XCTAssertEqual(s.judge(1, context(.ready, scanning: true)).failReason, "스캔이 Idle 로 끝남")
    }

    func testItem1TimeoutPendingThenFail() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        XCTAssertTrue(s.judge(1, context(.ready), after: AdapterOffDetector.timeout - 1).isPending)
        XCTAssertEqual(s.judge(1, context(.ready), after: AdapterOffDetector.timeout).failReason,
                       "최종 Disconnected(Failed:ADAPTER_UNAVAILABLE) 없음(마지막 Ready)")
        let none = Script()
        XCTAssertTrue(none.judge(1, context(.ready), after: 10).isPending)
        XCTAssertEqual(none.judge(1, context(.ready), after: 200).failReason, "어댑터 꺼짐 없음")
    }

    func testItem1NeedsHumanWhenNotReady() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        XCTAssertEqual(s.judge(1, context(.disconnectedInitial)).humanNote, "어댑터가 꺼질 때 Ready 가 아니었다")
    }

    // MARK: 2

    func testItem2PassAfterSettle() {
        var s = Script()
        s.command(.read, adapter: .poweredOff, failure: "ADAPTER_UNAVAILABLE")
        s.command(.connect, adapter: .poweredOff, failure: "ADAPTER_UNAVAILABLE")
        let ctx = context(offFinal, adapter: .poweredOff)
        XCTAssertTrue(s.judge(2, ctx).isPending, "3초 동안 상태 변화가 없는지 본다")
        let v = s.judge(2, ctx, after: 10)
        XCTAssertTrue(v.isPass, "\(v)")
        XCTAssertEqual(v.evidence.count, 2)
    }

    func testItem2FailsOnWrongConnectCode() {
        var s = Script()
        s.command(.connect, adapter: .poweredOff, failure: "NOT_READY")
        XCTAssertEqual(s.judge(2, context(offFinal, adapter: .poweredOff)).failReason, "connect 가 NOT_READY(기대 ADAPTER_UNAVAILABLE)")
    }

    func testItem2FailsOnOldReadCode() {
        // 0.2.2 부터 read 도 어댑터를 세션보다 먼저 본다(states.md §5 명령 진입 검사 순서). NOT_CONNECTED·NOT_READY 는 실패다
        for code in ["NOT_CONNECTED", "NOT_READY"] {
            var s = Script()
            s.command(.read, adapter: .poweredOff, failure: code)
            XCTAssertEqual(s.judge(2, context(offFinal, adapter: .poweredOff)).failReason, "read 가 \(code)(기대 ADAPTER_UNAVAILABLE)")
        }
    }

    func testItem2FailsWhenLinkChangesAfterCommand() {
        var s = Script()
        s.command(.connect, adapter: .poweredOff, failure: "ADAPTER_UNAVAILABLE")
        s.link(.connecting)
        XCTAssertEqual(s.judge(2, context(offFinal, adapter: .poweredOff)).failReason, "명령 뒤 연결 상태가 바뀜: Connecting")
    }

    func testItem2FailsWhenReadSucceeds() {
        var s = Script()
        s.command(.read, adapter: .poweredOff, failure: nil)
        XCTAssertEqual(s.judge(2, context(offFinal, adapter: .poweredOff)).failReason, "꺼진 상태에서 read 성공")
    }

    func testItem2IgnoresCommandsWhileReadyAndTimesOut() {
        var s = Script()
        s.command(.connect, adapter: .ready, failure: nil)
        let ctx = context(offFinal, adapter: .ready)
        XCTAssertTrue(s.judge(2, ctx, after: OffCommandsDetector.timeout - 1).isPending)
        XCTAssertEqual(s.judge(2, ctx, after: OffCommandsDetector.timeout).failReason, "꺼진 상태 명령 없음")
    }

    // MARK: 3

    private func reconnect(_ s: inout Script) {
        s.adapter(.ready, from: .poweredOff)
        s.link(.connecting)
        s.link(.discoveringServices)
        s.link(.configuring)
        s.link(.ready)
        s.add(.activeSubscriptionsChanged(s.id, [.probeValue]))
    }

    func testItem3Pass() {
        var s = Script()
        reconnect(&s)
        s.add(.notificationReceived(s.id, .probeValue, Data([2]), count: 1), after: 5)
        let v = s.judge(3, context(offFinal, adapter: .poweredOff))
        XCTAssertTrue(v.isPass, "\(v)")
        XCTAssertEqual(v.evidence, s.entries.map(\.seq))
    }

    /// 1·3 을 한 번에 시작해도 된다: Disconnected(Failed:ADAPTER_UNAVAILABLE) 뒤부터 센다
    func testItem3PassWhenArmedWhileReady() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(linkFailed)
        s.link(offFinal)
        s.add(.activeSubscriptionsChanged(s.id, []))
        s.command(.connect, adapter: .poweredOff, failure: "ADAPTER_UNAVAILABLE")
        reconnect(&s)
        s.add(.notificationReceived(s.id, .probeValue, Data([2]), count: 1))
        XCTAssertTrue(s.judge(3, context(.ready)).isPass)
    }

    func testItem3FailsOnTwoConnecting() {
        var s = Script()
        s.adapter(.ready, from: .poweredOff)
        s.link(.connecting)
        s.link(.connecting)
        XCTAssertEqual(s.judge(3, context(offFinal, adapter: .poweredOff)).failReason, "Connecting 두 번")
    }

    func testItem3FailsOnSecondConnectingAfterReadyBeforeNotification() {
        var s = Script()
        reconnect(&s)
        s.link(.connecting)
        XCTAssertEqual(s.judge(3, context(offFinal, adapter: .poweredOff)).failReason, "Connecting 두 번")
    }

    func testItem3FailsOnRecoveringInPath() {
        var s = Script()
        s.adapter(.ready, from: .poweredOff)
        s.link(linkFailed)
        XCTAssertEqual(s.judge(3, context(offFinal, adapter: .poweredOff)).failReason, "재연결 경로에 Recovering(LINK_FAILED)")
    }

    func testItem3MissingNotificationPendingThenFail() {
        var s = Script()
        reconnect(&s)
        let ctx = context(offFinal, adapter: .poweredOff)
        let ready = s.t
        XCTAssertTrue(s.judge(3, ctx, at: ready.addingTimeInterval(ReconnectDetector.notificationTimeout - 1)).isPending)
        XCTAssertEqual(s.judge(3, ctx, at: ready.addingTimeInterval(ReconnectDetector.notificationTimeout)).failReason, "Ready 뒤 알림 없음")
    }

    func testItem3NoReadyWithinReconnectTimeout() {
        var s = Script()
        s.adapter(.ready, from: .poweredOff)
        s.link(.connecting)
        let ctx = context(offFinal, adapter: .poweredOff)
        XCTAssertTrue(s.judge(3, ctx, after: 20).isPending)
        XCTAssertEqual(s.judge(3, ctx, after: 40).failReason, "켠 뒤 30초 안에 Ready 없음(Connecting)")
    }

    func testItem3MissingSubscriptionFails() {
        var s = Script()
        s.adapter(.ready, from: .poweredOff)
        [LinkState.connecting, .discoveringServices, .configuring, .ready].forEach { s.link($0) }
        s.add(.notificationReceived(s.id, .probeValue, Data([2]), count: 1))
        let ctx = context(offFinal, adapter: .poweredOff)
        XCTAssertTrue(s.judge(3, ctx).isPending)
        XCTAssertEqual(s.judge(3, ctx, after: 120).failReason, "activeSubscriptions 에 probe.value 없음")
    }

    func testItem3NeedsAutoReconnect() {
        XCTAssertEqual(Script().judge(3, context(offFinal, auto: false)).humanNote, "autoReconnect 를 켜고 시작")
    }

    // MARK: 4

    func testItem4PassAtWindowEnd() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(offFinal)
        s.adapter(.ready, from: .poweredOff, after: 5)
        let returned = s.t
        let ctx = context(.ready, auto: false)
        let pending = s.judge(4, ctx, at: returned.addingTimeInterval(NoReconnectDetector.window - 1))
        XCTAssertEqual(pending.outcome.deadline, returned.addingTimeInterval(NoReconnectDetector.window))
        XCTAssertTrue(s.judge(4, ctx, at: returned.addingTimeInterval(NoReconnectDetector.window)).isPass)
    }

    func testItem4FailsOnConnecting() {
        var s = Script()
        s.adapter(.ready, from: .poweredOff)
        s.link(.connecting, after: 1)
        XCTAssertEqual(s.judge(4, context(offFinal, adapter: .poweredOff, auto: false), after: 60).failReason, "autoReconnect 끔인데 Connecting")
    }

    func testItem4FailsOnConnectingLoggedBeforeAdapterLine() {
        var s = Script()
        s.link(.connecting)
        s.adapter(.ready, from: .poweredOff)
        XCTAssertEqual(s.judge(4, context(offFinal, adapter: .poweredOff, auto: false)).failReason, "autoReconnect 끔인데 Connecting")
    }

    func testItem4NeedsAutoReconnectOffAndTimesOut() {
        XCTAssertEqual(Script().judge(4, context(offFinal)).humanNote, "autoReconnect 를 끄고 시작")
        let s = Script()
        let ctx = context(offFinal, adapter: .poweredOff, auto: false)
        XCTAssertTrue(s.judge(4, ctx, after: NoReconnectDetector.adapterReturnTimeout - 1).isPending)
        XCTAssertEqual(s.judge(4, ctx, after: NoReconnectDetector.adapterReturnTimeout).failReason, "어댑터 Ready 복귀 없음")
    }

    // MARK: 5

    private func launchedOff(_ s: inout Script) {
        s.relaunch(.userLaunch, uptime: 5000)
        s.adapter(.poweredOff, from: .unknown)
        s.command(.connect, adapter: .poweredOff, link: .disconnectedInitial, failure: "ADAPTER_UNAVAILABLE", after: 3)
    }

    func testItem5PassWithConnectRightAfterOn() {
        var s = Script()
        launchedOff(&s)
        s.adapter(.ready, from: .poweredOff, after: 5)
        s.command(.connect, adapter: .ready, link: .disconnectedInitial, failure: nil, after: 1.5)
        [LinkState.connecting, .discoveringServices, .configuring, .ready].forEach { s.link($0) }
        let v = s.judge(5, context(.disconnectedInitial))
        XCTAssertTrue(v.isPass, "\(v)")
        XCTAssertEqual(v.outcome.detail, "끈 채 실행, 꺼진 채 connect ADAPTER_UNAVAILABLE, 켠 직후 connect → Ready")
    }

    func testItem5PassWithConnectWhileUnknown() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 5000)
        s.command(.connect, adapter: .unknown, link: .disconnectedInitial, failure: "ADAPTER_UNAVAILABLE", after: 0.2)
        s.adapter(.poweredOff, from: .unknown)
        s.adapter(.unknown, from: .poweredOff, after: 5)
        s.command(.connect, adapter: .unknown, link: .disconnectedInitial, failure: nil, after: 0.1)
        s.adapter(.ready, from: .unknown, after: 0.5)
        s.link(.connecting)
        s.link(.ready, after: 1)
        XCTAssertTrue(s.judge(5, context(.disconnectedInitial)).isPass)
    }

    func testItem5FailsWhenOffConnectDoesNotFailAdapterUnavailable() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 5000)
        s.adapter(.poweredOff, from: .unknown)
        s.command(.connect, adapter: .poweredOff, link: .disconnectedInitial, failure: "PERIPHERAL_NOT_FOUND")
        XCTAssertEqual(s.judge(5, context(.disconnectedInitial)).failReason, "꺼진 채 connect 가 PERIPHERAL_NOT_FOUND(기대 ADAPTER_UNAVAILABLE)")
    }

    func testItem5FailsWhenConnectRightAfterOnFails() {
        var s = Script()
        launchedOff(&s)
        s.adapter(.ready, from: .poweredOff, after: 5)
        s.command(.connect, adapter: .ready, link: .disconnectedInitial, failure: "ADAPTER_UNAVAILABLE", after: 1)
        XCTAssertEqual(s.judge(5, context(.disconnectedInitial)).failReason, "켠 직후 connect 가 ADAPTER_UNAVAILABLE")
    }

    func testItem5MissingPartPendingThenFail() {
        var s = Script()
        launchedOff(&s)
        s.adapter(.ready, from: .poweredOff, after: 5)
        s.command(.connect, adapter: .ready, link: .disconnectedInitial, failure: nil, after: 5)
        let ctx = context(.disconnectedInitial)
        let pending = s.judge(5, ctx, after: 60)
        XCTAssertEqual(pending.outcome.detail, "관찰: 끈 채 실행, 꺼진 채 connect ADAPTER_UNAVAILABLE / 대기: 켠 뒤 2초 안 connect")
        XCTAssertEqual(s.judge(5, ctx, after: LaunchOffDetector.timeout).failReason, "없음: 켠 뒤 2초 안 connect")
    }

    func testItem5WaitsForRelaunch() {
        XCTAssertTrue(Script().judge(5, context(.disconnectedInitial), after: 10).isPending)
        XCTAssertEqual(Script().judge(5, context(.disconnectedInitial), after: 400).failReason, "없음: 블루투스 끈 채 실행")
    }

    // MARK: 6

    func testItem6PassNeedsHumanConfirm() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(offFinal)
        reconnect(&s)
        s.add(.notificationReceived(s.id, .probeValue, Data([2]), count: 1))
        let v = s.judge(6, context(.ready))
        XCTAssertEqual(v.humanNote, "자동 판정 통과(비행기 모드 여부는 사람 확인)")
        XCTAssertEqual(v.evidence, s.entries.map(\.seq))
    }

    func testItem6FailsOnOffPartOrReconnectPart() {
        var off = Script()
        off.adapter(.poweredOff, from: .ready)
        off.link(.disconnectedFailed(code: "LINK_FAILED"))
        XCTAssertEqual(off.judge(6, context(.ready)).failReason, "예상 밖 상태 Disconnected(Failed:LINK_FAILED)")

        var on = Script()
        on.adapter(.poweredOff, from: .ready)
        on.link(offFinal)
        on.adapter(.ready, from: .poweredOff)
        on.link(.connecting)
        on.link(.connecting)
        XCTAssertEqual(on.judge(6, context(.ready)).failReason, "Connecting 두 번")
    }

    func testItem6PendingWhileAdapterOff() {
        var s = Script()
        s.adapter(.poweredOff, from: .ready)
        s.link(offFinal)
        XCTAssertEqual(s.judge(6, context(.ready)).outcome.detail, "블루투스 켜기 대기")
    }

    // MARK: 7

    func testItem7Pass() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 120, after: 90)
        s.adapter(.ready, from: .unknown)
        s.link(.connecting, after: 10)
        s.command(.connect, adapter: .ready, link: .disconnectedInitial, failure: nil)
        [LinkState.discoveringServices, .configuring, .ready].forEach { s.link($0) }
        let v = s.judge(7, context(.disconnectedInitial))
        XCTAssertEqual(v.outcome, .pass("uptime 120s, 첫 연결 Ready"))
    }

    func testItem7NeedsHumanWhenUptimeLong() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 600)
        XCTAssertEqual(s.judge(7, context(.disconnectedInitial)).humanNote, "재부팅 직후가 아님(uptime 600s)")
    }

    func testItem7FailsOnFirstConnectFailure() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 100)
        s.command(.connect, adapter: .ready, link: .disconnectedInitial, failure: "PERIPHERAL_NOT_FOUND")
        XCTAssertEqual(s.judge(7, context(.disconnectedInitial)).failReason, "첫 connect 가 PERIPHERAL_NOT_FOUND")

        var d = Script()
        d.relaunch(.userLaunch, uptime: 100)
        d.link(.connecting)
        d.link(.disconnectedFailed(code: "CONNECTION_TIMEOUT"))
        d.link(.connecting)
        d.link(.ready)
        XCTAssertEqual(d.judge(7, context(.disconnectedInitial)).failReason, "첫 연결이 Disconnected(Failed:CONNECTION_TIMEOUT)")
    }

    func testItem7TimeoutWithoutConnect() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 100)
        XCTAssertTrue(s.judge(7, context(.disconnectedInitial), after: RebootConnectDetector.timeout - 1).isPending)
        XCTAssertEqual(s.judge(7, context(.disconnectedInitial), after: RebootConnectDetector.timeout).failReason, "재부팅 뒤 연결 시도 없음")
    }

    // MARK: 8·9

    private func restored(_ s: inout Script, uptime: TimeInterval? = 5000) {
        s.relaunch(.bluetoothRelaunch, uptime: uptime, registration: s.id, after: 20)
        s.add(.snapshotTaken(label: "start 직후", GatewaySnapshot(
            adapter: .ready, scanning: false, sessions: [ObservedSession(id: s.id, link: .ready, subscriptions: [.probeValue])]
        )))
    }

    func testItem8Pass() {
        var s = Script()
        restored(&s)
        s.add(.notificationReceived(s.id, .probeValue, Data([1]), count: 1), after: 1)
        s.add(.appPhaseChanged("active"), after: 10)
        let v = s.judge(8, context(.ready))
        XCTAssertEqual(v.outcome, .pass("복원 재실행, 앱을 열기 전 세션 Ready·알림"))
        XCTAssertEqual(v.evidence, s.entries.map(\.seq))
    }

    func testItem8FailsOnForegroundLaunch() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 5000, registration: s.id)
        XCTAssertEqual(s.judge(8, context(.ready)).failReason, "복원 재실행 없이 사용자 실행")
    }

    func testItem8FailsWhenOpenedBeforeNotification() {
        var s = Script()
        restored(&s)
        s.add(.appPhaseChanged("active"), after: 3)
        s.add(.notificationReceived(s.id, .probeValue, Data([1]), count: 1), after: 1)
        XCTAssertEqual(s.judge(8, context(.ready)).failReason, "복원 재실행은 있었으나 앱을 열기 전 없음: 알림")
    }

    func testItem8PendingInBackgroundThenTimeout() {
        var s = Script()
        restored(&s)
        XCTAssertEqual(s.judge(8, context(.ready)).outcome.detail, "복원 재실행 중 대기: 알림")
        XCTAssertEqual(s.judge(8, context(.ready), after: RestorationDetector.timeout).failReason, "복원 재실행은 있었으나 없음: 알림")
        XCTAssertTrue(Script().judge(8, context(.ready), after: 60).isPending)
        XCTAssertEqual(Script().judge(8, context(.ready), after: RestorationDetector.timeout).failReason, "복원 재실행 없음")
    }

    func testItem8NeedsRegistration() {
        var s = Script()
        s.relaunch(.bluetoothRelaunch, uptime: 5000, registration: nil)
        XCTAssertEqual(s.judge(8, context(.ready)).humanNote, "등록 없이 재실행됨(현재 대상으로 저장 필요)")
    }

    func testItem9PassAfterReboot() {
        var s = Script()
        restored(&s, uptime: 95)
        s.add(.notificationReceived(s.id, .probeValue, Data([1]), count: 1))
        XCTAssertEqual(s.judge(9, context(.ready)).outcome, .pass("복원 재실행, uptime 95s, 앱을 열기 전 세션 Ready·알림"))
    }

    func testItem9NeedsHumanWhenNotAfterReboot() {
        var s = Script()
        restored(&s, uptime: 3600)
        s.add(.notificationReceived(s.id, .probeValue, Data([1]), count: 1))
        XCTAssertEqual(s.judge(9, context(.ready)).humanNote, "재부팅 직후가 아님(uptime 3600s)")
    }

    /// 복원 실행 없이 사용자가 열었다: 관찰 결과로 실패, 근거는 그 실행 줄
    func testItem9FailsWithoutRelaunch() {
        var s = Script()
        s.relaunch(.userLaunch, uptime: 200, registration: s.id)
        let v = s.judge(9, context(.ready))
        XCTAssertEqual(v.failReason, "재부팅 뒤 복원 실행 없음")
        XCTAssertEqual(v.evidence, [s.entries[0].seq])
        XCTAssertEqual(Script().judge(9, context(.ready), after: RestorationDetector.timeout).failReason, "재부팅 뒤 복원 실행 없음")
    }

    // MARK: 공통

    func testEntriesBeforeArmAreIgnored() {
        var s = Script()
        s.add(.adapterChanged(.poweredOff, previous: .ready), after: -10)
        s.add(.linkChanged(s.id, offFinal), after: 0)
        XCTAssertEqual(s.judge(1, context(.ready), after: 1).outcome.detail, "블루투스 끄기 대기")
    }

    func testLegacyEntriesWithoutFactsAreIgnored() {
        let legacy = [LogEntry(seq: 1, launch: 1, at: Date(timeIntervalSince1970: 1_800_000_001), kind: .adapter, text: "adapter PoweredOff")]
        let v = ChecklistDetectors.evaluate(1, armedAt: Date(timeIntervalSince1970: 1_800_000_000), entries: legacy,
                                            now: Date(timeIntervalSince1970: 1_800_000_002), context: context(.ready))
        XCTAssertTrue(v.isPending)
    }
}
