import Foundation

// MARK: 점검 항목 자동 판정 결과

/// "시작"을 누른 순간의 세션 상태. 판정은 이 문맥과 그 뒤 기록만 본다
public struct ArmContext: Hashable, Codable, Sendable {
    public let deviceId: DeviceId?
    public let autoReconnect: Bool
    public let link: LinkState
    public let adapter: AdapterStatus
    public let scanning: Bool
    public init(deviceId: DeviceId?, autoReconnect: Bool, link: LinkState, adapter: AdapterStatus, scanning: Bool) {
        self.deviceId = deviceId
        self.autoReconnect = autoReconnect
        self.link = link
        self.adapter = adapter
        self.scanning = scanning
    }
}

public struct ChecklistVerdict: Hashable, Sendable {
    public enum Outcome: Hashable, Codable, Sendable {
        /// 기다리는 것. deadline 이 지나면 실패로 바뀐다
        case pending(String, deadline: Date?)
        case pass(String)
        case fail(String)
        /// 기록만으로 가를 수 없다. 사람이 확인해 판정한다
        case needsHuman(String)

        public var isFinal: Bool {
            if case .pending = self { return false }
            return true
        }

        public var verdict: Verdict {
            switch self {
            case .pending: .pending
            case .pass: .pass
            case .fail: .fail
            case .needsHuman: .needsHuman
            }
        }

        public var label: String {
            switch self {
            case .pending: "진행 중"
            case .pass: "통과"
            case .fail: "실패"
            case .needsHuman: "사람 확인"
            }
        }

        public var detail: String {
            switch self {
            case let .pending(text, _), let .pass(text), let .fail(text), let .needsHuman(text): text
            }
        }

        public var deadline: Date? {
            if case let .pending(_, deadline) = self { return deadline }
            return nil
        }
    }

    public let outcome: Outcome
    /// 근거 기록 줄의 seq(시간순)
    public let evidence: [Int]

    public init(_ outcome: Outcome, evidence: [Int] = []) {
        self.outcome = outcome
        var seen = Set<Int>()
        self.evidence = evidence.sorted().filter { seen.insert($0).inserted }
    }
}

public enum VerdictSource: String, Codable, Sendable {
    case auto, manual

    public var label: String {
        switch self {
        case .auto: "자동"
        case .manual: "수동"
        }
    }
}

/// 한 항목의 자동 판정 상태. 사람이 덮어써도 남겨 근거를 보인다
public struct AutoJudgement: Hashable, Codable, Sendable {
    public let armedAt: Date
    public let context: ArmContext
    public var outcome: ChecklistVerdict.Outcome
    /// 근거 줄(표기된 글). 기록을 비워도 남는다
    public var evidence: [String]
    public var judgedAt: Date?

    public init(armedAt: Date, context: ArmContext, outcome: ChecklistVerdict.Outcome = .pending("판정 대기", deadline: nil),
                evidence: [String] = [], judgedAt: Date? = nil) {
        self.armedAt = armedAt
        self.context = context
        self.outcome = outcome
        self.evidence = evidence
        self.judgedAt = judgedAt
    }
}
