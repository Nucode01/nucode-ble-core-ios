import Foundation
import ManualTestDomain

/// 점검표 상태의 소유자. 바꿀 때마다 저장한다
@MainActor
public final class ChecklistBoard {
    public internal(set) var checklist: Checklist
    public private(set) var storeError: String?
    public var onChange: (@MainActor () -> Void)?
    let store: any ChecklistStore
    let clock: any Clock

    public init(store: any ChecklistStore, clock: any Clock) {
        self.store = store
        self.clock = clock
        do {
            checklist = Checklist(results: try store.load())
        } catch {
            checklist = Checklist()
            storeError = "점검표 읽기 실패: \(error)"
        }
    }

    func persist() {
        do {
            try store.save(checklist.results)
            storeError = nil
        } catch {
            storeError = "점검표 저장 실패: \(error)"
        }
        onChange?()
    }
}

@MainActor
public struct MarkChecklistItem {
    let board: ChecklistBoard
    public init(board: ChecklistBoard) { self.board = board }

    public func callAsFunction(_ id: Int, verdict: Verdict, note: String) throws(DomainError) {
        try board.checklist.mark(id, verdict: verdict, note: note, at: board.clock.now())
        board.persist()
    }

    public func resetAll() {
        board.checklist.reset()
        board.persist()
    }
}

/// "시작": 지금 세션 상태를 문맥으로 잡고 이 순간부터 기록을 판정한다
@MainActor
public struct ArmChecklistItem {
    let board: ChecklistBoard
    let state: ConsoleState
    public init(board: ChecklistBoard, state: ConsoleState) { self.board = board; self.state = state }

    public func callAsFunction(_ id: Int) throws(DomainError) {
        let context = ArmContext(
            deviceId: state.session.deviceId,
            autoReconnect: state.session.autoReconnect,
            link: state.session.link,
            adapter: state.adapter,
            scanning: state.scan == .scanning
        )
        try board.checklist.arm(id, context: context, at: board.clock.now())
        board.persist()
        EvaluateChecklist(board: board, state: state)()
    }
}

/// 판정 중인 항목을 기록으로 다시 판정한다. 새 기록 줄마다, 1초마다(기한), 앱 실행 때(8·9 는 재실행 뒤 판정) 부른다.
/// 바뀐 것이 있을 때만 저장한다
@MainActor
public struct EvaluateChecklist {
    let board: ChecklistBoard
    let state: ConsoleState
    let timeZone: TimeZone
    public init(board: ChecklistBoard, state: ConsoleState, timeZone: TimeZone = .current) {
        self.board = board
        self.state = state
        self.timeZone = timeZone
    }

    public func callAsFunction() {
        let judging = board.checklist.judging
        guard !judging.isEmpty else { return }
        let now = board.clock.now()
        let entries = state.log.entries
        var changed = false
        for id in judging {
            guard let auto = board.checklist.result(for: id).auto else { continue }
            let verdict = ChecklistDetectors.evaluate(id, armedAt: auto.armedAt, entries: entries, now: now, context: auto.context)
            let wanted = Set(verdict.evidence)
            let lines = entries.filter { wanted.contains($0.seq) }.map { LogTime.line($0, timeZone) }
            changed = board.checklist.applyAuto(id, verdict.outcome, evidence: lines, at: now) || changed
        }
        if changed { board.persist() }
    }
}

/// 점검표 결과 + 기록 전체를 텍스트 보고서로 만든다
public struct ExportReport: Sendable {
    let timeZone: TimeZone
    public init(timeZone: TimeZone = .current) { self.timeZone = timeZone }

    public func callAsFunction(checklist: Checklist, log: [LogEntry], generatedAt: Date, header: String = "") -> String {
        var lines = ["# BLE 수동 시험 보고서", "생성: \(LogTime.full(generatedAt, timeZone))"]
        if !header.isEmpty { lines.append(header) }
        lines.append("")
        lines.append("## 점검표")
        for item in Checklist.items {
            let result = checklist.result(for: item.id)
            var line = "[\(result.verdict.label)] \(item.id). \(item.title)"
            if let at = result.updatedAt { line += " (\(LogTime.full(at, timeZone)))" }
            if result.auto != nil { line += " [\(result.source.label)]" }
            lines.append(line)
            if !result.note.isEmpty { lines.append("    메모: \(result.note)") }
            if let auto = result.auto {
                lines.append("    자동 판정: \(auto.outcome.label) \(auto.outcome.detail) (시작 \(LogTime.full(auto.armedAt, timeZone)))")
                lines += auto.evidence.map { "      \($0)" }
            }
        }
        lines.append("")
        lines.append("## 기록 (\(log.count)줄)")
        lines += log.map { LogTime.line($0, timeZone) }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// 기록 줄 표기. 화면과 보고서가 같이 쓴다
public enum LogTime {
    /// `#seq L<실행> yyyy-MM-dd HH:mm:ss.SSS [kind] text`
    public static func line(_ entry: LogEntry, _ timeZone: TimeZone = .current) -> String {
        "#\(entry.seq) L\(entry.launch) \(full(entry.at, timeZone)) [\(entry.kind.rawValue)] \(entry.text)"
    }

    public static func full(_ date: Date, _ timeZone: TimeZone = .current) -> String {
        let (c, millis) = split(date, timeZone)
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%03d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis)
    }

    /// `HH:mm:ss.SSS`
    public static func clock(_ date: Date, _ timeZone: TimeZone = .current) -> String {
        let (c, millis) = split(date, timeZone)
        return String(format: "%02d:%02d:%02d.%03d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0, millis)
    }

    /// 밀리초로 반올림한 뒤 초와 나머지로 가른다(부동소수 오차로 1ms 내려가지 않게)
    static func split(_ date: Date, _ timeZone: TimeZone) -> (DateComponents, Int) {
        let total = Int64((date.timeIntervalSince1970 * 1000).rounded())
        let seconds = Date(timeIntervalSince1970: Double(total.floorDiv(1000)))
        return (components(seconds, timeZone), Int(total - total.floorDiv(1000) * 1000))
    }

    static func components(_ date: Date, _ timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }
}

private extension Int64 {
    func floorDiv(_ d: Int64) -> Int64 { self >= 0 ? self / d : (self - d + 1) / d }
}
