/// 기록 레인. 레인 안의 순서만 판정하고 레인 사이의 순서는 보지 않는다
public enum Lane: String, Sendable, CaseIterable {
    case state, result, notify, active
    /// 아래는 확장 레인. 시나리오의 `expect`에 있을 때만 기록·출력한다
    case adapter, scan, found, services, peer

    public var isExtension: Bool {
        switch self {
        case .state, .result, .notify, .active: false
        default: true
        }
    }

    /// 값이 바뀔 때만 의미가 있어 연속 중복을 합치는 레인
    var mergesDuplicates: Bool {
        switch self {
        case .active, .adapter, .scan, .services: true
        default: false
        }
    }
}

public enum Verdict: Sendable, Equatable {
    case pass
    case fail(reason: String)
}

/// 시나리오 한 번의 공개 관찰 기록
public struct ContractLog: Sendable, Equatable {
    private var lanes: [Lane: [String]] = [:]

    public init() {}

    public subscript(lane: Lane) -> [String] {
        lanes[lane] ?? []
    }

    public mutating func append(_ entry: String, to lane: Lane) {
        if lane.mergesDuplicates, lanes[lane]?.last == entry { return }
        lanes[lane, default: []].append(entry)
    }

    /// 활성 구독 집합을 `{a,b}` 모양으로 남긴다(이름순, 공백 없음)
    public mutating func appendActive(_ symbols: some Sequence<String>) {
        append(Self.renderActive(symbols), to: .active)
    }

    public static func renderActive(_ symbols: some Sequence<String>) -> String {
        "{" + Set(symbols).sorted().joined(separator: ",") + "}"
    }

    /// `expect`에 적힌 레인만 판정한다
    public func judge(_ expect: [Lane: [String]]) -> Verdict {
        let failed = Lane.allCases.filter { lane in
            guard let expected = expect[lane] else { return false }
            return !ContractMatcher.matches(expected: expected, actual: self[lane])
        }
        if failed.isEmpty { return .pass }
        return .fail(reason: "mismatch: " + failed.map(\.rawValue).joined(separator: ","))
    }

    /// `CONTRACT|<플랫폼>|<id>|<레인>|<기록>` 줄들. 레인 순서는 Lane 선언 순서(state, result, notify, active, adapter, scan, found, services, peer)
    public func lines(platform: String, scenarioId: String) -> [String] {
        Lane.allCases.flatMap { lane in
            self[lane].map { "CONTRACT|\(platform)|\(scenarioId)|\(lane.rawValue)|\($0)" }
        }
    }

    public static func verdictLine(_ verdict: Verdict, platform: String, scenarioId: String) -> String {
        switch verdict {
        case .pass: "CONTRACT|\(platform)|\(scenarioId)|verdict|PASS"
        case .fail(let reason): "CONTRACT|\(platform)|\(scenarioId)|verdict|FAIL|\(reason)"
        }
    }
}
