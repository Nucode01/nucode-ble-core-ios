import Foundation
import ManualTestApplication
import ManualTestDomain
import ManualTestInfrastructure
import XCTest

@MainActor
final class ChecklistAutoTests: XCTestCase {
    let id = DeviceId("AAAAAAAA-1111")
    var clock: ManualClock!
    var gateway: FakeGateway!
    var state: ConsoleState!
    var store: MemoryChecklistStore!
    var board: ChecklistBoard!
    var observe: ObserveGateway!

    override func setUp() async throws {
        clock = ManualClock()
        gateway = FakeGateway()
        state = ConsoleState(logStore: MemoryLogStore(), clock: clock)
        store = MemoryChecklistStore()
        board = ChecklistBoard(store: store, clock: clock)
        observe = ObserveGateway(gateway: gateway, state: state)
        let evaluate = EvaluateChecklist(board: board, state: state, timeZone: TimeZone(identifier: "UTC")!)
        state.onEntry = { _ in evaluate() }
    }

    private func feed(_ events: [GatewayEvent]) {
        for event in events {
            clock.advance(0.1)
            observe.handle(event)
        }
    }

    private func readyWithScan() async {
        await SelectDevice(state: state)(id)
        feed([.adapter(.ready), .scan(.scanning), .link(id, .connecting), .link(id, .discoveringServices), .link(id, .configuring), .link(id, .ready)])
    }

    /// 점검 1: 시작 → 기록 줄마다 판정 → 통과, 근거 줄 저장
    func testArmedItemPassesFromLogAndPersists() async throws {
        await readyWithScan()
        try ArmChecklistItem(board: board, state: state)(1)
        XCTAssertEqual(board.checklist.result(for: 1).auto?.context,
                       ArmContext(deviceId: id, autoReconnect: true, link: .ready, adapter: .ready, scanning: true))
        XCTAssertEqual(board.checklist.judging, [1])
        feed([.adapter(.poweredOff), .link(id, .recovering(code: "LINK_FAILED")),
              .link(id, .disconnectedFailed(code: "ADAPTER_UNAVAILABLE")), .scan(.failed(code: "SCAN_STOPPED_BY_ADAPTER"))])

        let result = board.checklist.result(for: 1)
        XCTAssertEqual(result.verdict, .pass)
        XCTAssertEqual(result.source, .auto)
        XCTAssertEqual(result.auto?.outcome, .pass("Recovering(LINK_FAILED) 거쳐 Disconnected(Failed:ADAPTER_UNAVAILABLE), 스캔 Idle(Failed:SCAN_STOPPED_BY_ADAPTER)"))
        XCTAssertEqual(result.auto?.evidence.count, 4)
        XCTAssertTrue(result.auto?.evidence.first?.hasSuffix("[adapter] adapter PoweredOff") == true, "\(result.auto?.evidence ?? [])")
        XCTAssertTrue(board.checklist.judging.isEmpty)
        XCTAssertEqual(ChecklistBoard(store: store, clock: clock).checklist.result(for: 1), result, "저장된다")
    }

    /// 사건이 없어도 1초 틱이 기한을 넘기면 실패로 바꾼다. 대기 중에는 바뀐 것이 없으면 저장하지 않는다
    func testTickTimesOutAndSavesOnlyOnChange() async throws {
        await readyWithScan()
        try ArmChecklistItem(board: board, state: state)(1)
        let saves = store.saves
        let evaluate = EvaluateChecklist(board: board, state: state)
        for _ in 0..<5 { clock.advance(1); evaluate() }
        XCTAssertEqual(store.saves, saves)
        XCTAssertEqual(board.checklist.result(for: 1).auto?.outcome.detail, "블루투스 끄기 대기")
        clock.advance(AdapterOffDetector.timeout)
        evaluate()
        XCTAssertEqual(board.checklist.result(for: 1).verdict, .fail)
        XCTAssertEqual(board.checklist.result(for: 1).auto?.outcome, .fail("어댑터 꺼짐 없음"))
        XCTAssertEqual(store.saves, saves + 1)
    }

    /// 사람이 덮어쓰면 수동이 되고 자동 판정은 멈추지만 근거는 남는다
    func testManualOverrideStopsAutoAndKeepsEvidence() async throws {
        await readyWithScan()
        try ArmChecklistItem(board: board, state: state)(3)
        try MarkChecklistItem(board: board)(3, verdict: .skip, note: "펌웨어 없음")
        feed([.adapter(.poweredOff)])
        let result = board.checklist.result(for: 3)
        XCTAssertEqual(result.verdict, .skip)
        XCTAssertEqual(result.source, .manual)
        XCTAssertNotNil(result.auto)
        XCTAssertTrue(board.checklist.judging.isEmpty)
        try ArmChecklistItem(board: board, state: state)(3)
        XCTAssertEqual(board.checklist.result(for: 3).source, .auto, "다시 시작하면 자동으로 돌아간다")
        XCTAssertEqual(board.checklist.result(for: 3).note, "펌웨어 없음", "메모는 둔다")
    }

    /// 명령 줄에 부른 순간의 어댑터·연결 상태가, 연결 줄에 직전 상태가 실린다(점검 2 판정 재료)
    func testCommandAndLinkFactsCarryContext() async throws {
        await SelectDevice(state: state)(id)
        feed([.adapter(.poweredOff)])
        gateway.fail("connect", code: "ADAPTER_UNAVAILABLE")
        await Connect(gateway: gateway, state: state)()
        feed([.link(id, .connecting), .link(id, .ready)])
        let facts = state.log.entries.compactMap(\.fact)
        guard case let .command(.connect, context?, failure)? = facts.first(where: { if case .command(.connect, _, _) = $0 { true } else { false } }) else {
            return XCTFail("connect 사실 없음 \(facts)")
        }
        XCTAssertEqual(failure, "ADAPTER_UNAVAILABLE")
        XCTAssertEqual(context.adapter, .poweredOff)
        XCTAssertEqual(context.device, id)
        XCTAssertEqual(facts.suffix(2), [.link(id, .connecting, previous: nil), .link(id, .ready, previous: .connecting)])
        XCTAssertEqual(facts[1], .adapter(.poweredOff, previous: .unknown))
    }

    func testRecordLaunchStoresUptimeFact() async {
        let launch = RecordLaunch(gateway: gateway, state: state, registrationStore: MemoryRegistrationStore(), settleDelay: .zero)
        await launch(LaunchContext(
            launchedInBackground: false, appState: "inactive", protectedDataAvailable: true, hasBluetoothCentralsKey: false, systemUptime: 95.7
        )).value
        let first = state.log.entries[0]
        XCTAssertEqual(first.fact, .launch(LaunchFact(reason: .userLaunch, systemUptime: 95.7, adapter: .unknown, registration: nil)))
        XCTAssertTrue(first.text.hasSuffix("등록=없음 uptime=95s"), first.text)
    }

    func testReportIncludesAutoVerdictAndEvidence() throws {
        var checklist = Checklist()
        let context = ArmContext(deviceId: id, autoReconnect: true, link: .ready, adapter: .ready, scanning: false)
        try checklist.arm(4, context: context, at: Date(timeIntervalSince1970: 60))
        checklist.applyAuto(4, .needsHuman("autoReconnect 를 끄고 시작"), evidence: ["#1 L1 x"], at: Date(timeIntervalSince1970: 61))
        let report = ExportReport(timeZone: TimeZone(identifier: "UTC")!)(checklist: checklist, log: [], generatedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(report.contains("""
        [확인] 4. autoReconnect 끄고 1–3 반복 (1970-01-01 00:01:01.000) [자동]
            자동 판정: 사람 확인 autoReconnect 를 끄고 시작 (시작 1970-01-01 00:01:00.000)
              #1 L1 x
        """), report)
    }
}

/// 이전 형식 파일도 읽는다
final class BackwardCompatibilityTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ManualTestKitCompat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testOldLogLinesDecodeWithoutFactAndNewLinesRoundTrip() throws {
        let old = #"{"seq":1,"launch":1,"at":100,"kind":"adapter","text":"adapter PoweredOff"}"# + "\n"
        let unknownFact = #"{"seq":2,"launch":1,"at":101,"kind":"adapter","text":"미래","fact":{"somethingNew":{}}}"# + "\n"
        try Data((old + unknownFact).utf8).write(to: directory.appending(path: "events.jsonl"))
        let store = FileEventLogStore(directory: directory)
        var entries = try store.load()
        XCTAssertEqual(entries.map(\.seq), [1, 2], "모르는 사실이 있어도 줄은 남는다")
        XCTAssertTrue(entries.allSatisfy { $0.fact == nil })

        var log = EventLog(restoring: entries)
        let context = CommandContext(device: DeviceId("X"), startedAt: Date(timeIntervalSince1970: 102), adapter: .poweredOff, link: .ready)
        let new = log.append(.commandFailed(.connect, code: "ADAPTER_UNAVAILABLE", message: "m", context: context), at: Date(timeIntervalSince1970: 103))
        try store.append(new)
        entries = try store.load()
        XCTAssertEqual(entries.last, new)
        XCTAssertEqual(new.fact, .command(.connect, context, failure: "ADAPTER_UNAVAILABLE"))
    }

    func testOldChecklistFileDecodesAsManual() throws {
        let old = #"{"2":{"verdict":"fail","note":"NOT_READY","updatedAt":100}}"#
        try Data(old.utf8).write(to: directory.appending(path: "checklist.json"))
        let result = try XCTUnwrap(try FileChecklistStore(directory: directory).load()[2])
        XCTAssertEqual(result.verdict, .fail)
        XCTAssertEqual(result.source, .manual)
        XCTAssertNil(result.auto)
    }

    func testAutoJudgementRoundTrips() throws {
        var checklist = Checklist()
        let context = ArmContext(deviceId: DeviceId("X"), autoReconnect: false, link: .disconnectedFailed(code: "ADAPTER_UNAVAILABLE"), adapter: .poweredOff, scanning: true)
        try checklist.arm(4, context: context, at: Date(timeIntervalSince1970: 10))
        checklist.applyAuto(4, .pending("대기", deadline: Date(timeIntervalSince1970: 40)), evidence: ["a"], at: Date(timeIntervalSince1970: 11))
        try checklist.arm(8, context: context, at: Date(timeIntervalSince1970: 12))
        checklist.applyAuto(8, .fail("복원 재실행 없음"), evidence: [], at: Date(timeIntervalSince1970: 13))
        let store = FileChecklistStore(directory: directory)
        try store.save(checklist.results)
        XCTAssertEqual(try store.load(), checklist.results)
        XCTAssertEqual(Checklist(results: try store.load()).judging, [4], "재실행 뒤에도 판정 중인 항목을 이어 본다")
    }
}
