import XCTest

/// 점검표 자동 실행(auto/run-checklist.sh 가 순서대로 부른다). 시험 하나가 한 단계다.
///
/// - 설치·실행 중인 앱에 번들 ID 로 붙는다. 스크립트는 대상 앱을 다시 설치하지 않는 xctestrun 으로 돌린다(프로세스·연결 유지).
/// - 판정은 앱의 자동 판정이 한다. 여기서는 조작하고 판정이 대기(pending)를 벗어날 때까지 기다린다.
///   판정이 실패여도 시험은 실패하지 않는다(시험 실패 = 자동화 문제). 판정은 `AUTO| VERDICT` 줄과 checklist.json 으로 본다.
/// - 블루투스·비행기 모드는 설정 앱으로만 바꾼다(제어 센터 토글은 어댑터를 끄지 않을 수 있다).
final class ManualTestUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "kr.co.nucode.ble.ManualTest")
    let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    static let deviceName = "Nordic_UART_Service"

    override func setUp() {
        continueAfterFailure = false
        addUIInterruptionMonitor(withDescription: "시스템 알림") { alert in Self.tapAllow(alert) }
    }

    // MARK: 준비

    /// 등록 없음 · 대상 선택 · autoReconnect 켬 · 연결 Ready · probe.value 구독 · 알림 수신
    func testPrepareConnectSubscribe() {
        setAirplane(false)
        setBluetooth(true)
        openApp()
        tab("세션")
        if text("session.savedRegistration") != "없음" || text("session.activeRegistration") != "없음" {
            tap("session.clearRegistration")
            XCTAssertTrue(waitFor(10) { self.text("session.savedRegistration") == "없음" }, "등록 해제 안 됨")
            log("등록 해제 뒤 앱 다시 실행")
            app.terminate()
            openApp()
            tab("세션")
        }
        XCTAssertTrue(waitFor(30) { self.text("session.adapter") == "Ready" }, "어댑터 Ready 아님: \(text("session.adapter"))")
        disconnectIfNeeded()
        selectDevice()
        tab("세션")
        setAutoReconnect(true)
        connectAndWaitReady()
        subscribeAndWaitNotification()
    }

    // MARK: 1 · 2 · 3

    func testItem1_BluetoothOff() {
        openApp()
        tab("세션")
        requireReadySubscribed()
        tab("기기")
        if text("device.scan") != "Scanning" {
            tap("device.scanStart")
            XCTAssertTrue(waitFor(10) { self.text("device.scan") == "Scanning" }, "스캔 시작 안 됨")
        }
        arm(1)
        setBluetooth(false)
        openApp()
        waitVerdict(1, timeout: 130)
    }

    func testItem2_OffCommands() {
        openApp()
        arm(2)
        tab("세션")
        tap("session.read")
        pause(1)
        tap("session.connect")
        waitVerdict(2, timeout: 130)
    }

    func testItem3_BluetoothOn() {
        openApp()
        tab("세션")
        setAutoReconnect(true)
        arm(3)
        setBluetooth(true)
        openApp()
        waitVerdict(3, timeout: 150)
    }

    // MARK: 6 (3 이 남긴 Ready·구독 상태에서. 3 이 재연결하지 않았으면 다시 연결·구독한다)

    func testItem6_AirplaneMode() {
        if ProcessInfo.processInfo.environment["PRIME_AIRPLANE"] == "1" { primeAirplaneTurnsBluetoothOff() }
        openApp()
        tab("세션")
        ensureReadySubscribed()
        arm(6)
        setAirplane(true)
        pause(5)
        setAirplane(false)
        openApp()
        waitVerdict(6, timeout: 250)
    }

    /// iOS 는 비행기 모드 중 블루투스를 켠 적이 있으면 다음 비행기 모드에서 블루투스를 끄지 않는다(기기 설정).
    /// 비행기 모드 중 블루투스를 끄고 나오면 다음 비행기 모드가 블루투스를 끈다. 시험 기기 설정을 바꾸는 준비라 선택이다(PRIME_AIRPLANE=1)
    func primeAirplaneTurnsBluetoothOff() {
        setAirplane(true)
        setBluetooth(false)
        setAirplane(false)
        pause(3)
        let toggle = bluetoothSwitch()
        log("비행기 모드 준비 뒤 블루투스 스위치 \(toggle.value ?? "-")")
        if (toggle.value as? String) != "1" { flip(toggle, to: true, name: "bluetooth") }
    }

    // MARK: 4

    func testItem4_NoAutoReconnect() {
        openApp()
        tab("세션")
        disconnectIfNeeded()
        setAutoReconnect(false)
        connectAndWaitReady()
        arm(4)
        setBluetooth(false)
        pause(3)
        setBluetooth(true)
        openApp()
        waitVerdict(4, timeout: 90)
    }

    // MARK: 5

    /// README 절차는 끈 채 실행한 뒤 곧바로 연결이지만, 등록 없이 새로 실행하면 대상이 없어 connect 가 NO_DEVICE_SELECTED 다
    /// (꺼진 채로는 스캔도 못 한다). 그래서 같은 실행 안에서: 끈 채 실행 → 켜고 스캔·선택 → 끄고 connect → 켜고 곧바로 connect.
    func testItem5_LaunchWithBluetoothOff() {
        openApp()
        tab("세션")
        if text("session.savedRegistration") != "없음" { tap("session.clearRegistration") }
        arm(5)
        setBluetooth(false)
        log("블루투스 끈 채 앱 다시 실행")
        app.terminate()
        openApp()
        tab("세션")
        XCTAssertTrue(waitFor(15) { self.text("session.adapter") == "PoweredOff" }, "끈 채 실행인데 어댑터 \(text("session.adapter"))")
        // 대상 고르기(켜야 스캔된다)
        setBluetooth(true)
        openApp()
        tab("세션")
        XCTAssertTrue(waitFor(15) { self.text("session.adapter") == "Ready" }, "어댑터 Ready 아님")
        selectDevice()
        tap("device.scanStop")
        // 꺼진 채 connect
        setBluetooth(false)
        openApp()
        tab("세션")
        XCTAssertTrue(waitFor(15) { self.text("session.adapter") == "PoweredOff" }, "어댑터 PoweredOff 아님")
        tap("session.connect")
        pause(2)
        // 켜고 곧바로 connect. 2초 창을 놓치면(자동화 지연) 끄고 켜기를 다시 한다
        for attempt in 1...3 {
            // 2초 창: 스위치 값 확인·요소 조회를 건너뛴다. connect 는 미리 잰 화면 좌표로 누른다
            let frame = reveal("session.connect").frame
            let toggle = bluetoothSwitch()
            XCTAssertEqual(toggle.value as? String, "0", "블루투스가 이미 켜져 있음")
            toggle.tap()
            app.activate()
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            log("켠 직후 connect 시도 \(attempt) at=\(ISO8601DateFormatter().string(from: Date()))")
            tab("점검표")
            let status = reveal("checklist.status.5")
            _ = waitFor(40) { (status.value as? String) != "pending" || !self.detail(5).contains("켠 뒤 2초 안 connect") }
            if !detail(5).contains("켠 뒤 2초 안 connect") || attempt == 3 { break }
            log("2초 창 놓침: \(detail(5))")
            tab("세션")
            setBluetooth(false)
            openApp()
            tab("세션")
            _ = waitFor(15) { self.text("session.adapter") == "PoweredOff" }
        }
        waitVerdict(5, timeout: 60)
    }

    // MARK: 8

    /// 대상 + autoReconnect 켬 → 현재 대상으로 저장 → 앱 다시 실행(등록 적용) → 자동 연결·구독 확인 → 시작.
    /// 그다음 스크립트가 Mac 에서 SIGKILL 하고 펌웨어 알림을 보낸다
    func testItem8_Arm() {
        openApp()
        tab("세션")
        disconnectIfNeeded()
        setAutoReconnect(true)
        tap("session.saveRegistration")
        XCTAssertTrue(waitFor(10) { self.text("session.savedRegistration").contains("auto=true") }, "등록 저장 안 됨: \(text("session.savedRegistration"))")
        log("등록 적용하려고 앱 다시 실행")
        app.terminate()
        openApp()
        tab("세션")
        XCTAssertTrue(waitFor(10) { self.text("session.activeRegistration").contains("auto=true") }, "이번 실행 등록 없음")
        requireReadySubscribed(timeout: 60)
        arm(8)
    }

    func testItem8_Verify() {
        openApp()
        waitVerdict(8, timeout: 90)
    }

    // MARK: 9 · 7 (재부팅 한 번)

    /// 8 뒤 복원 재실행된 앱(등록·Ready·구독)에서 9 와 7 을 함께 시작한다. 그다음 스크립트가 재부팅한다
    func testItem9And7_Arm() {
        openApp()
        tab("세션")
        XCTAssertTrue(text("session.activeRegistration").contains("auto=true"), "이번 실행 등록 없음")
        requireReadySubscribed(timeout: 60)
        arm(9)
        arm(7)
    }

    /// 재부팅 뒤 앱을 연다. 9 는 연 순간까지의 기록으로, 7 은 이 실행의 첫 연결로 판정된다
    func testItem9And7_Verify() {
        openApp()
        waitVerdict(9, timeout: 60)
        tab("점검표")
        let status = reveal("checklist.status.7")
        _ = waitFor(20) { (status.value as? String) != "pending" }
        if (status.value as? String) == "pending", detail(7).contains("첫 연결 대기") {
            // 등록 기기가 스스로 연결하지 않았다: README 절차대로 스캔·연결
            log("7: 자동 연결 없음, 스캔·연결")
            selectDevice()
            tab("세션")
            tap("session.connect")
        }
        waitVerdict(7, timeout: 90)
    }

    /// 끝정리: 블루투스 켬, 비행기 모드 끔
    func testRestoreRadios() {
        setAirplane(false)
        setBluetooth(true)
    }

    // MARK: 앱 조작

    func openApp(file: StaticString = #filePath, line: UInt = #line) {
        app.activate()
        dismissSpringboardAlerts()
        XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30), "앱 탭 막대 없음", file: file, line: line)
    }

    func tab(_ name: String) {
        let button = app.tabBars.buttons[name]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "탭 \(name) 없음")
        button.tap()
    }

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// 목록을 위아래로 밀어 보이게 한다
    @discardableResult
    func reveal(_ id: String, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let target = element(id)
        if target.waitForExistence(timeout: 2), target.isHittable { return target }
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 {
            if target.exists, target.isHittable { return target }
            list.swipeUp(velocity: .slow)
        }
        for _ in 0..<16 {
            if target.exists, target.isHittable { return target }
            list.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(target.exists && target.isHittable, "\(id) 를 찾지 못함", file: file, line: line)
        return target
    }

    func tap(_ id: String) {
        reveal(id).tap()
        log("tap \(id)")
    }

    func text(_ id: String) -> String {
        let target = element(id)
        if target.exists { return target.label }
        return reveal(id).label
    }

    func detail(_ item: Int) -> String {
        let target = element("checklist.detail.\(item)")
        return target.exists ? target.label : ""
    }

    func setAutoReconnect(_ on: Bool) {
        let toggle = reveal("session.autoReconnect")
        let want = on ? "1" : "0"
        for _ in 0..<3 where (toggle.value as? String) != want {
            toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            _ = waitFor(3) { (toggle.value as? String) == want }
        }
        XCTAssertEqual(toggle.value as? String, want, "autoReconnect 를 \(on) 로 못 바꿈")
        log("autoReconnect=\(on)")
    }

    func disconnectIfNeeded() {
        let link = text("session.link")
        guard !link.hasPrefix("Disconnected") else { return }
        tap("session.disconnect")
        XCTAssertTrue(waitFor(20) { self.text("session.link").hasPrefix("Disconnected") }, "해제 안 됨: \(text("session.link"))")
    }

    func selectDevice() {
        tab("기기")
        tap("device.scanStart")
        let row = app.buttons["device.row.\(Self.deviceName)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 30), "\(Self.deviceName) 발견 못 함")
        row.tap()
        XCTAssertTrue(waitFor(5) { (row.value as? String) == "selected" }, "대상 선택 안 됨")
        log("대상 선택 \(Self.deviceName)")
    }

    func connectAndWaitReady() {
        tab("세션")
        tap("session.connect")
        XCTAssertTrue(waitFor(40) { self.text("session.link") == "Ready" }, "Ready 아님: \(text("session.link"))")
        log("Ready")
    }

    func subscribeAndWaitNotification() {
        tap("session.subscribe")
        XCTAssertTrue(waitFor(15) { self.text("session.subscriptions") == "{probe.value}" }, "구독 안 됨: \(text("session.subscriptions"))")
        let before = Int(text("session.notificationCount")) ?? 0
        XCTAssertTrue(waitFor(40) { (Int(self.text("session.notificationCount")) ?? 0) > before }, "알림 없음(펌웨어 NOTIFY 확인)")
        log("구독·알림 수신")
    }

    /// 앞 항목이 Ready·구독을 남기지 않았으면(판정 실패 등) autoReconnect 켬으로 다시 연결·구독
    func ensureReadySubscribed() {
        if text("session.link") != "Ready" {
            log("Ready 아님(\(text("session.link"))): 다시 연결")
            disconnectIfNeeded()
            setAutoReconnect(true)
            connectAndWaitReady()
        }
        if text("session.subscriptions") != "{probe.value}" { subscribeAndWaitNotification() }
        requireReadySubscribed()
    }

    func requireReadySubscribed(timeout: TimeInterval = 10) {
        XCTAssertTrue(waitFor(timeout) { self.text("session.link") == "Ready" }, "Ready 아님: \(text("session.link"))")
        XCTAssertTrue(waitFor(timeout) { self.text("session.subscriptions") == "{probe.value}" }, "구독 없음: \(text("session.subscriptions"))")
    }

    // MARK: 점검표

    func arm(_ item: Int) {
        tab("점검표")
        reveal("checklist.arm.\(item)").tap()
        let status = element("checklist.status.\(item)")
        XCTAssertTrue(waitFor(5) { status.exists && status.label != "대기" }, "항목 \(item) 시작 안 됨")
        log("ARMED item=\(item) at=\(ISO8601DateFormatter().string(from: Date())) status=\(status.label)")
    }

    /// 판정이 pending 을 벗어날 때까지. 판정 결과로 실패하지 않는다
    @discardableResult
    func waitVerdict(_ item: Int, timeout: TimeInterval) -> String {
        tab("점검표")
        let status = reveal("checklist.status.\(item)")
        let done = waitFor(timeout) {
            let value = status.value as? String ?? ""
            return !value.isEmpty && value != "pending"
        }
        let value = status.value as? String ?? "?"
        log("VERDICT item=\(item) verdict=\(value) status=\(status.label) detail=\(detail(item))")
        XCTAssertTrue(done, "항목 \(item) 판정이 \(Int(timeout))초 안에 끝나지 않음: \(status.label) \(detail(item))")
        return value
    }

    // MARK: 설정 앱

    func settingsRoot() {
        settings.launch()
        let airplane = settings.descendants(matching: .any)["com.apple.settings.airplaneMode"]
        for _ in 0..<4 {
            if airplane.waitForExistence(timeout: 3) { return }
            let back = settings.navigationBars.firstMatch.buttons.element(boundBy: 0)
            if back.exists { back.tap() }
        }
        XCTAssertTrue(airplane.exists, "설정 첫 화면을 찾지 못함")
    }

    func setBluetooth(_ on: Bool) {
        flip(bluetoothSwitch(), to: on, name: "bluetooth")
    }

    /// 설정 > Bluetooth 화면의 스위치
    func bluetoothSwitch() -> XCUIElement {
        settingsRoot()
        let row = settings.descendants(matching: .any)["com.apple.settings.bluetooth"]
        XCTAssertTrue(row.waitForExistence(timeout: 5), "설정 Bluetooth 줄 없음")
        row.tap()
        // 한국어·영어 모두 'Bluetooth'. 이름이 달라도 이 화면의 첫 스위치다
        let named = settings.switches["Bluetooth"].firstMatch
        let toggle = named.waitForExistence(timeout: 5) ? named : settings.tables.switches.firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Bluetooth 스위치 없음")
        return toggle
    }

    func setAirplane(_ on: Bool) {
        settingsRoot()
        var toggle = settings.descendants(matching: .any)["com.apple.settings.airplaneMode"]
        if toggle.elementType != .switch {
            // 줄이 화면 이동 버튼인 배치: 들어가서 첫 스위치
            toggle.tap()
            toggle = settings.switches.firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "비행기 모드 스위치 없음")
        }
        flip(toggle, to: on, name: "airplane")
    }

    func flip(_ toggle: XCUIElement, to on: Bool, name: String) {
        let want = on ? "1" : "0"
        for attempt in 0..<3 where (toggle.value as? String) != want {
            // 줄 전체가 스위치인 경우 가운데를 누르면 안 바뀐다: 오른쪽 끝을 누른다
            if attempt == 0, toggle.frame.width < 80 { toggle.tap() }
            else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap() }
            confirmSettingsAlert()
            _ = waitFor(5) { (toggle.value as? String) == want }
        }
        XCTAssertEqual(toggle.value as? String, want, "설정 \(name) 을 \(on) 로 못 바꿈")
        XCTAssertFalse(settings.alerts.firstMatch.exists, "설정 확인 창이 남아 있음")
        log("SETTINGS \(name)=\(on ? "on" : "off") at=\(ISO8601DateFormatter().string(from: Date()))")
    }

    /// 끄기 확인 창("Bluetooth를 끄겠습니까?" → 끄기). 스위치 값은 확인 전에 이미 바뀌어 보이므로 창을 먼저 본다
    func confirmSettingsAlert() {
        let alert = settings.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        log("설정 확인 창: \(alert.label)")
        for label in ["끄기", "Turn Off", "켜기", "Turn On", "확인", "OK"] where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
        // 이름이 다르면 취소가 아닌 마지막 버튼
        let buttons = alert.buttons.allElementsBoundByIndex.filter { !["취소", "Cancel"].contains($0.label) }
        buttons.last?.tap()
    }

    // MARK: 공통

    static func tapAllow(_ alert: XCUIElement) -> Bool {
        for label in ["허용", "Allow", "확인", "OK"] {
            let button = alert.buttons[label]
            if button.exists { button.tap(); return true }
        }
        return false
    }

    func dismissSpringboardAlerts() {
        let alert = springboard.alerts.firstMatch
        if alert.exists { _ = Self.tapAllow(alert) }
    }

    func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            pause(1)
        }
        return condition()
    }

    func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func log(_ message: String) {
        print("AUTO| \(message)")
    }
}
