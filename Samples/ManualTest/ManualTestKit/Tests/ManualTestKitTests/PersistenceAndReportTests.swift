import Foundation
import ManualTestApplication
import ManualTestDomain
import ManualTestInfrastructure
import XCTest

final class PersistenceAndReportTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "ManualTestKitTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testChecklistRoundTrip() throws {
        let store = FileChecklistStore(directory: directory)
        XCTAssertEqual(try store.load(), [:])
        var checklist = Checklist()
        try checklist.mark(1, verdict: .pass, note: "Recovering 없이 바로 끊김", at: Date(timeIntervalSince1970: 100))
        try checklist.mark(9, verdict: .skip, note: "", at: Date(timeIntervalSince1970: 200))
        try store.save(checklist.results)
        XCTAssertEqual(try FileChecklistStore(directory: directory).load(), checklist.results)
    }

    @MainActor
    func testChecklistBoardPersistsMarks() throws {
        let store = FileChecklistStore(directory: directory)
        let board = ChecklistBoard(store: store, clock: SteppingClock())
        try MarkChecklistItem(board: board)(2, verdict: .fail, note: "NOT_READY 로 옴")
        let reloaded = ChecklistBoard(store: store, clock: SteppingClock())
        XCTAssertEqual(reloaded.checklist.result(for: 2).verdict, .fail)
        XCTAssertEqual(reloaded.checklist.result(for: 2).note, "NOT_READY 로 옴")
    }

    func testEventLogRoundTripSkipsBrokenLines() throws {
        let store = FileEventLogStore(directory: directory)
        let entries = [
            LogEntry(seq: 1, launch: 1, at: Date(timeIntervalSince1970: 1.25), kind: .link, text: "a"),
            LogEntry(seq: 2, launch: 2, at: Date(timeIntervalSince1970: 2.5), kind: .notification, text: "b"),
        ]
        try store.append(entries[0])
        let handle = try FileHandle(forWritingTo: directory.appending(path: "events.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{broken\n".utf8))
        try handle.close()
        try store.append(entries[1])
        XCTAssertEqual(try FileEventLogStore(directory: directory).load(), entries)
        try store.clear()
        XCTAssertEqual(try store.load(), [])
    }

    func testRegistrationRoundTrip() throws {
        let store = FileRegistrationStore(directory: directory)
        XCTAssertNil(try store.load())
        let registration = DeviceRegistration(deviceId: DeviceId("X"), autoReconnect: true, subscribe: [.probeValue])
        try store.save(registration)
        XCTAssertEqual(try store.load(), registration)
        try store.save(nil)
        XCTAssertNil(try store.load())
    }

    func testReportFormat() throws {
        var checklist = Checklist()
        try checklist.mark(1, verdict: .pass, note: "", at: Date(timeIntervalSince1970: 60))
        try checklist.mark(2, verdict: .fail, note: "read 가 NOT_READY", at: Date(timeIntervalSince1970: 61.5))
        let log = [
            LogEntry(seq: 7, launch: 3, at: Date(timeIntervalSince1970: 62.042), kind: .link, text: "AAAAAAAA Ready"),
        ]
        let report = ExportReport(timeZone: TimeZone(identifier: "UTC")!)(
            checklist: checklist, log: log, generatedAt: Date(timeIntervalSince1970: 3600), header: "기기: iPhone XR"
        )
        let expected = """
        # BLE 수동 시험 보고서
        생성: 1970-01-01 01:00:00.000
        기기: iPhone XR

        ## 점검표
        [PASS] 1. Ready 에서 블루투스 끄기 (1970-01-01 00:01:00.000)
        [FAIL] 2. 꺼진 상태에서 read·connect (1970-01-01 00:01:01.500)
            메모: read 가 NOT_READY
        [미실시] 3. 블루투스 다시 켜기
        [미실시] 4. autoReconnect 끄고 1–3 반복
        [미실시] 5. 블루투스 끈 채 앱 시작
        [미실시] 6. 비행기 모드로 1–3
        [미실시] 7. 폰 재부팅 뒤 앱 실행
        [미실시] 8. 연결·구독 중 시스템 종료(SIGKILL)
        [미실시] 9. 8 을 폰 재부팅 뒤(앱 실행 없이)

        ## 기록 (1줄)
        #7 L3 1970-01-01 00:01:02.042 [link] AAAAAAAA Ready

        """
        XCTAssertEqual(report, expected)
    }
}
