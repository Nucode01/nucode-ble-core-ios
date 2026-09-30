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
            lines.append(line)
            if !result.note.isEmpty { lines.append("    메모: \(result.note)") }
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
