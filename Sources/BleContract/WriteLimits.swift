/// MTU·write 한도 형식(CANDIDATE-33·CANDIDATE-5)과, iOS 코어에 아직 없는 기능을 쓰는 draft 판정의 한 곳
extension Scenario {
    /// expect 에 `writeLimits`가 있다. `await writeLimits`도 expect 를 요구하므로 이것으로 충분하다
    public var usesWriteLimits: Bool {
        expect[.writeLimits] != nil
    }

    /// iOS 코어에 아직 없는 기능을 쓰는 draft 면 그 이유, 아니면 nil.
    /// sim·device 시험이 이 시나리오의 실패를 known issue 로 둔다. 구현 뒤 통과하면 시험이 알린다
    public var pendingIosSupport: String? {
        guard status == .draft else { return nil }
        if usesDescriptors { return "CANDIDATE-32 descriptor" }
        if usesWriteLimits { return "CANDIDATE-5 writeLimits" }
        return nil
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
