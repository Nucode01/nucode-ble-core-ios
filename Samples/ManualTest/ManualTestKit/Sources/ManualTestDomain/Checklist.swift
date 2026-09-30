import Foundation

// MARK: 릴리스 수동 점검표 (전달 계획 §6)

public enum Verdict: String, Codable, CaseIterable, Sendable {
    case pending, pass, fail, skip

    public var label: String {
        switch self {
        case .pending: "미실시"
        case .pass: "PASS"
        case .fail: "FAIL"
        case .skip: "SKIP"
        }
    }
}

public struct ChecklistItem: Hashable, Sendable, Identifiable {
    public let id: Int
    public let title: String
    public let expectation: String
}

public struct ChecklistResult: Hashable, Codable, Sendable {
    public var verdict: Verdict
    public var note: String
    public var updatedAt: Date?
    public init(verdict: Verdict = .pending, note: String = "", updatedAt: Date? = nil) {
        self.verdict = verdict
        self.note = note
        self.updatedAt = updatedAt
    }
}

public struct Checklist: Sendable {
    public static let items: [ChecklistItem] = [
        .init(id: 1, title: "Ready 에서 블루투스 끄기",
              expectation: "최종 Disconnected(Failed:ADAPTER_UNAVAILABLE). 그 전에 Recovering(LINK_FAILED) 가 잠깐 보일 수 있다. 스캔 중이었으면 Idle(Failed:SCAN_STOPPED_BY_ADAPTER)"),
        .init(id: 2, title: "꺼진 상태에서 read·connect",
              expectation: "즉시 ADAPTER_UNAVAILABLE. 연결 상태는 바뀌지 않는다"),
        .init(id: 3, title: "블루투스 다시 켜기",
              expectation: "재연결 정확히 한 번 Connecting→DiscoveringServices→Configuring→Ready. 알림 재개, activeSubscriptions {probe.value}"),
        .init(id: 4, title: "autoReconnect 끄고 1–3 반복",
              expectation: "재연결하지 않는다"),
        .init(id: 5, title: "블루투스 끈 채 앱 시작",
              expectation: "connect 실패. 켠 직후 connect 는 기다린다(Unknown 최대 2000ms)"),
        .init(id: 6, title: "비행기 모드로 1–3",
              expectation: "1–3 과 같다"),
        .init(id: 7, title: "폰 재부팅 뒤 앱 실행",
              expectation: "첫 connect 성공"),
        .init(id: 8, title: "연결·구독 중 시스템 종료(SIGKILL)",
              expectation: "기기 알림에 iOS 가 앱을 백그라운드로 다시 실행하고 세션 복원, 알림 수신"),
        .init(id: 9, title: "8 을 폰 재부팅 뒤(앱 실행 없이)",
              expectation: "동작 여부 모름. 재실행 기록·알림 기록으로 관찰한다"),
    ]

    public private(set) var results: [Int: ChecklistResult]

    public init(results: [Int: ChecklistResult] = [:]) {
        self.results = results.filter { id, _ in Self.items.contains { $0.id == id } }
    }

    public func result(for id: Int) -> ChecklistResult { results[id] ?? ChecklistResult() }

    public mutating func mark(_ id: Int, verdict: Verdict, note: String, at: Date) throws(DomainError) {
        guard Self.items.contains(where: { $0.id == id }) else { throw .unknownChecklistItem(id) }
        results[id] = ChecklistResult(verdict: verdict, note: note, updatedAt: at)
    }

    public mutating func reset() { results = [:] }
}
