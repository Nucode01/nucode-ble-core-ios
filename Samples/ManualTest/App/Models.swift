import ManualTestApplication
import ManualTestDomain
import Darwin
import Observation
import UIKit

/// 표현 계층의 상태 사본. 응용 계층 `ConsoleState` 가 바뀔 때마다 다시 읽는다
@MainActor
@Observable
final class ConsoleModel {
    private(set) var adapter: AdapterStatus = .unknown
    private(set) var scan: ScanStatus = .idle
    private(set) var devices: [DiscoveredDevice] = []
    private(set) var session = TestSession()
    private(set) var entries: [LogEntry] = []
    private(set) var launch = 1
    private(set) var registration: DeviceRegistration?
    private(set) var activeRegistration: DeviceRegistration?
    private(set) var storeError: String?

    var scanByService = false
    var namePrefix = ProbeProfile.advertisedName
    var nusText = "hello"

    @ObservationIgnored private let state: ConsoleState
    @ObservationIgnored private let gateway: any BleGateway
    @ObservationIgnored private let registrationStore: any RegistrationStore

    init(state: ConsoleState, gateway: any BleGateway, registrationStore: any RegistrationStore) {
        self.state = state
        self.gateway = gateway
        self.registrationStore = registrationStore
        state.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func refresh() {
        adapter = state.adapter
        scan = state.scan
        devices = state.devices
        session = state.session
        entries = state.log.entries
        launch = state.log.launch
        registration = state.registration
        activeRegistration = state.activeRegistration
        storeError = state.storeError
    }

    var recentCommands: [LogEntry] { entries.filter { $0.kind == .command }.suffix(5).reversed() }

    // MARK: 명령. 결과는 기록으로 본다

    func startScan() {
        let criteria: ScanCriteria = scanByService ? .service(uuid: ProbeProfile.nusServiceUUID) : .namePrefix(namePrefix)
        run { await StartScan(gateway: $0.gateway, state: $0.state)(criteria) }
    }

    func stopScan() { run { await StopScan(gateway: $0.gateway, state: $0.state)() } }
    func select(_ id: DeviceId) { run { await SelectDevice(state: $0.state)(id) } }
    func setAutoReconnect(_ on: Bool) { run { await SetAutoReconnect(state: $0.state)(on) } }
    func connect() { run { await Connect(gateway: $0.gateway, state: $0.state)() } }
    func disconnect() { run { await Disconnect(gateway: $0.gateway, state: $0.state)() } }
    func subscribe() { run { await Subscribe(gateway: $0.gateway, state: $0.state)() } }
    func unsubscribe() { run { await Unsubscribe(gateway: $0.gateway, state: $0.state)() } }
    func read() { run { await ReadValue(gateway: $0.gateway, state: $0.state)() } }
    func writeNus() {
        let text = nusText
        run { await WriteNus(gateway: $0.gateway, state: $0.state)(text) }
    }
    func saveRegistration() { run { await SaveRegistration(state: $0.state, store: $0.registrationStore)() } }
    func clearRegistration() { run { await ClearRegistration(state: $0.state, store: $0.registrationStore)() } }
    func clearLog() { state.clearLog() }

    /// 시스템 종료 흉내(점검 8·9). 사용자 강제 종료(앱 전환기)와 달리 iOS 가 복원 재실행할 수 있다
    func killSelf() {
        state.recordAppPhase("SIGKILL 스스로 보냄")
        kill(getpid(), SIGKILL)
    }

    private func run(_ body: @escaping @MainActor (ConsoleModel) async -> Void) {
        Task { await body(self) }
    }
}

@MainActor
@Observable
final class ChecklistModel {
    private(set) var checklist: Checklist
    private(set) var storeError: String?
    @ObservationIgnored private let board: ChecklistBoard
    @ObservationIgnored private let state: ConsoleState
    @ObservationIgnored private let clock: any Clock

    init(board: ChecklistBoard, state: ConsoleState, clock: any Clock) {
        self.board = board
        self.state = state
        self.clock = clock
        checklist = board.checklist
        storeError = board.storeError
        board.onChange = { [weak self] in
            guard let self else { return }
            checklist = self.board.checklist
            storeError = self.board.storeError
        }
    }

    func mark(_ id: Int, verdict: Verdict, note: String) {
        try? MarkChecklistItem(board: board)(id, verdict: verdict, note: note)
    }

    func resetAll() { MarkChecklistItem(board: board).resetAll() }

    /// 점검표 결과 + 기록 전체
    func report() -> String {
        let device = UIDevice.current
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        return ExportReport()(
            checklist: checklist,
            log: state.log.entries,
            generatedAt: clock.now(),
            header: "기기: \(device.model) iOS \(device.systemVersion) · 앱 \(version)"
        )
    }
}
