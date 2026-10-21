/// MTU·write 한도 형식(CANDIDATE-33·CANDIDATE-5)과, iOS 코어에 아직 없는 기능을 쓰는 draft 판정의 한 곳
extension Scenario {
    /// iOS 코어에 아직 없는 기능을 쓰는 draft 면 그 이유, 아니면 nil.
    /// sim·device 시험이 이 시나리오의 실패를 known issue 로 둔다. 구현 뒤 통과하면 시험이 알린다
    public var pendingIosSupport: String? {
        guard status == .draft else { return nil }
        if usesDescriptors { return "CANDIDATE-32 descriptor" }
        return nil
    }
}

extension ContractLog {
    /// `writeLimits` 레인 기록. 값이 있으면 `<withResponse>/<withoutResponse>`(10진수), 없으면 `null`
    public static func renderWriteLimits(_ limits: (withResponse: Int, withoutResponse: Int)?) -> String {
        guard let limits else { return "null" }
        return "\(limits.withResponse)/\(limits.withoutResponse)"
    }
}

extension ScenarioObserver {
    /// `writeLimits` 레인. 첫 값(`null`)도 넣는다. 시나리오의 `expect`에 이 레인이 있을 때만 남는다
    public func writeLimits(_ limits: (withResponse: Int, withoutResponse: Int)?) {
        let entry = ContractLog.renderWriteLimits(limits)
        recorder.update(lane: .writeLimits) { $0.log.append(entry, to: .writeLimits) }
    }
}

extension StepParser {
    static let requestedMtuRange = 23...517

    /// connect 의 `requestedMtu`. Android 전용이라 `platforms`가 정확히 `["android"]`일 때만 받는다.
    /// iOS 는 요청 MTU 가 없어 값을 담지 않는다
    func checkRequestedMtu(_ o: JSONObject) throws {
        guard o.has("requestedMtu") else { return }
        guard platforms == [.android] else {
            throw ContractError("\(o.path).requestedMtu: only allowed when platforms is exactly [\"android\"]")
        }
        let mtu = try o.int("requestedMtu")
        guard Self.requestedMtuRange.contains(mtu) else {
            throw ContractError("\(o.path).requestedMtu: must be 23...517, got \(mtu)")
        }
    }
}
