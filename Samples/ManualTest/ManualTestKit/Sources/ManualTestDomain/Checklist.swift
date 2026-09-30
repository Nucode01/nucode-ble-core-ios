import Foundation

// MARK: 릴리스 수동 점검표 (전달 계획 §6)

public enum Verdict: String, Codable, CaseIterable, Sendable {
    case pending, pass, fail, skip
    /// 자동 판정이 사람 확인을 요구했다
    case needsHuman

    public var label: String {
        switch self {
        case .pending: "미실시"
        case .pass: "PASS"
        case .fail: "FAIL"
        case .skip: "SKIP"
        case .needsHuman: "확인"
        }
    }
}

public struct ChecklistItem: Hashable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let expectation: String
    /// "시작" 뒤 사람이 할 일(짧게)
    public let instruction: String
}

public struct ChecklistResult: Hashable, Codable, Sendable {
    public var verdict: Verdict
    public var note: String
    public var updatedAt: Date?
    /// verdict 를 누가 정했나. 이전 형식은 수동
    public var source: VerdictSource
    /// "시작"을 누른 적이 있으면 자동 판정 상태
    public var auto: AutoJudgement?

    public init(verdict: Verdict = .pending, note: String = "", updatedAt: Date? = nil,
                source: VerdictSource = .manual, auto: AutoJudgement? = nil) {
        self.verdict = verdict
        self.note = note
        self.updatedAt = updatedAt
        self.source = source
        self.auto = auto
    }

    /// 자동 판정이 아직 기록을 보고 있다
    public var isJudging: Bool {
        source == .auto && auto.map { !$0.outcome.isFinal } == true
    }

    enum CodingKeys: String, CodingKey { case verdict, note, updatedAt, source, auto }

    /// 이전 형식(verdict·note·updatedAt 만)도 읽는다
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        source = (try? c.decodeIfPresent(VerdictSource.self, forKey: .source)) ?? .manual
        auto = (try? c.decodeIfPresent(AutoJudgement.self, forKey: .auto)) ?? nil
    }
}

public struct Checklist: Sendable {
    public static let items: [ChecklistItem] = [
        .init(id: 1, title: "Ready 에서 블루투스 끄기",
              expectation: "최종 Disconnected(Failed:ADAPTER_UNAVAILABLE). 그 전에 Recovering(LINK_FAILED) 가 잠깐 보일 수 있다(autoReconnect 켬일 때만). 스캔 중이었으면 Idle(Failed:SCAN_STOPPED_BY_ADAPTER)",
              instruction: "Ready 에서 시작 → 설정 앱에서 블루투스 끄기"),
        .init(id: 2, title: "꺼진 상태에서 read·connect",
              expectation: "connect 는 즉시 ADAPTER_UNAVAILABLE, read 는 NOT_CONNECTED(연결 없음) 또는 ADAPTER_UNAVAILABLE. 연결 상태는 바뀌지 않는다",
              instruction: "꺼진 채 시작 → probe.value 읽기, 연결"),
        .init(id: 3, title: "블루투스 다시 켜기",
              expectation: "재연결 정확히 한 번 Connecting→DiscoveringServices→Configuring→Ready. 알림 재개, activeSubscriptions {probe.value}",
              instruction: "autoReconnect 켬 · 꺼진 채 시작 → 블루투스 켜기 → 펌웨어 알림"),
        .init(id: 4, title: "autoReconnect 끄고 1–3 반복",
              expectation: "재연결하지 않는다",
              instruction: "autoReconnect 끔으로 연결 → 시작 → 끄기 → 켜기 → 30초 대기"),
        .init(id: 5, title: "블루투스 끈 채 앱 시작",
              expectation: "connect 실패. 켠 직후 connect 는 기다린다(Unknown 최대 2000ms)",
              instruction: "등록 해제 · 시작 → 끄기 → 앱 종료·실행 → 연결 → 켜고 2초 안에 연결"),
        .init(id: 6, title: "비행기 모드로 1–3",
              expectation: "1–3 과 같다",
              instruction: "Ready·구독 · 시작 → 비행기 모드 켜기 → 끄기 → 펌웨어 알림"),
        .init(id: 7, title: "폰 재부팅 뒤 앱 실행",
              expectation: "첫 connect 성공",
              instruction: "시작 → 재부팅 → 잠금 해제 → 앱 실행 → 스캔·연결"),
        .init(id: 8, title: "연결·구독 중 시스템 종료(SIGKILL)",
              expectation: "기기 알림에 iOS 가 앱을 백그라운드로 다시 실행하고 세션 복원, 알림 수신",
              instruction: "등록·Ready·구독 · 시작 → SIGKILL → 펌웨어 알림 → 몇 초 뒤 앱 열기"),
        .init(id: 9, title: "8 을 폰 재부팅 뒤(앱 실행 없이)",
              expectation: "동작 여부 모름. 재실행 기록·알림 기록으로 관찰한다",
              instruction: "등록·Ready·구독 · 시작 → 재부팅 → 잠금 해제 → 펌웨어 알림 → 앱 열기"),
    ]

    public private(set) var results: [Int: ChecklistResult]

    public init(results: [Int: ChecklistResult] = [:]) {
        self.results = results.filter { id, _ in Self.items.contains { $0.id == id } }
    }

    public func result(for id: Int) -> ChecklistResult { results[id] ?? ChecklistResult() }

    /// 사람의 판정. 자동 판정 상태는 근거로 남기고 더 보지 않는다
    public mutating func mark(_ id: Int, verdict: Verdict, note: String, at: Date) throws(DomainError) {
        guard Self.items.contains(where: { $0.id == id }) else { throw .unknownChecklistItem(id) }
        results[id] = ChecklistResult(verdict: verdict, note: note, updatedAt: at, source: .manual, auto: results[id]?.auto)
    }

    /// "시작". 이전 판정을 지우고 이 순간부터 기록을 본다. 메모는 둔다
    public mutating func arm(_ id: Int, context: ArmContext, at: Date) throws(DomainError) {
        guard Self.items.contains(where: { $0.id == id }) else { throw .unknownChecklistItem(id) }
        results[id] = ChecklistResult(
            verdict: .pending, note: results[id]?.note ?? "", updatedAt: at,
            source: .auto, auto: AutoJudgement(armedAt: at, context: context)
        )
    }

    /// 자동 판정 반영. 판정 중이 아니면(사람이 덮어썼거나 이미 끝났으면) 무시한다. 바뀌었으면 true
    @discardableResult
    public mutating func applyAuto(_ id: Int, _ outcome: ChecklistVerdict.Outcome, evidence: [String], at: Date) -> Bool {
        guard var result = results[id], result.isJudging, var auto = result.auto else { return false }
        guard auto.outcome != outcome || auto.evidence != evidence else { return false }
        auto.outcome = outcome
        auto.evidence = evidence
        if outcome.isFinal {
            auto.judgedAt = at
            result.verdict = outcome.verdict
            result.updatedAt = at
        }
        result.auto = auto
        results[id] = result
        return true
    }

    /// 자동 판정이 아직 기록을 보는 항목
    public var judging: [Int] {
        Self.items.map(\.id).filter { results[$0]?.isJudging == true }
    }

    public mutating func reset() { results = [:] }
}
