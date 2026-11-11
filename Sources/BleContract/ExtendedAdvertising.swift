// extended 광고 형식(CANDIDATE-36b): startScan 의 `extendedAdvertising`, 기기 사건 `extAdv`, `androidAdv` 레인.
// 모두 Android 전용이다. iOS 는 읽기 규칙만 맞추고 이 시나리오를 돌리지 않는다

extension StepParser {
    static let extAdvRange = 1...60_000

    /// startScan 의 `extendedAdvertising`. iOS 에는 extended 스캔 API 가 없어 값을 담지 않는다
    func checkExtendedAdvertising(_ o: JSONObject) throws {
        guard o.has("extendedAdvertising") else { return }
        guard platforms == [.android] else {
            throw ContractError("\(o.path).extendedAdvertising: only allowed when platforms is exactly [\"android\"]")
        }
        _ = try o.bool("extendedAdvertising")
    }

    /// 기기 사건 `extAdv`: 펌웨어가 `ms` 동안 extended 광고 세트를 켠다
    func parseExtAdv(_ o: JSONObject) throws -> DeviceEvent {
        try o.only(["device", "ms"])
        guard platforms == [.android] else {
            throw ContractError("\(o.path): extAdv is only allowed when platforms is exactly [\"android\"]")
        }
        let ms = try o.int("ms")
        guard Self.extAdvRange.contains(ms) else {
            throw ContractError("\(o.path).ms: must be 1...60000, got \(ms)")
        }
        return .extAdv(ms: ms)
    }
}

extension Scenario {
    /// `expect`에 `androidAdv` 레인을 두는 시나리오는 `platforms`가 정확히 `["android"]`여야 한다
    static func checkAndroidAdvLane(_ lanes: Set<Lane>, platforms: [Platform], path: String) throws {
        guard lanes.contains(.androidAdv), platforms != [.android] else { return }
        throw ContractError("\(path).expect.androidAdv: only allowed when platforms is exactly [\"android\"]")
    }
}
