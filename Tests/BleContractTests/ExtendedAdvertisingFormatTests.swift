import BleContract
import Foundation
import Testing

/// extended 광고 형식(CANDIDATE-36b): startScan `extendedAdvertising`, 기기 사건 `extAdv`, `androidAdv` 레인.
/// 기기 정의를 인라인으로 만들어 계약 폴더 없이 돈다
struct ExtendedAdvertisingFormatTests {
    static let profileJSON = """
    {"format": 1, "name": "p", "advertisedName": "n", "characteristics": {"probe.value": {
      "service": "6e7a0001-5c3a-4b8e-9d1f-0a1b2c3d4e5f", "uuid": "6e7a0002-5c3a-4b8e-9d1f-0a1b2c3d4e5f", "properties": ["read"]}}}
    """

    static let android = #"["android"]"#
    static let ready = #"{ "call": "connect" }, { "await": "state", "is": "Ready" }"#

    static func parse(platforms: String?, steps: String, expect: String = "{}") throws -> Scenario {
        let profile = try PeripheralProfile.parse(Data(profileJSON.utf8), expectedName: "p")
        let platformsField = platforms.map { #""platforms": \#($0), "# } ?? ""
        let json = """
        {"format": 1, "id": "inline", "summary": "s", "status": "draft", "runsOn": ["sim"], \(platformsField)
         "peripheral": "p", "steps": [\(steps)], "expect": \(expect)}
        """
        return try Scenario.parse(Data(json.utf8), expectedId: "inline") { _ in profile }
    }

    static func rejects(platforms: String?, steps: String, expect: String = "{}", _ fragment: String) {
        do {
            _ = try parse(platforms: platforms, steps: steps, expect: expect)
            Issue.record("accepted, expected rejection containing \"\(fragment)\"")
        } catch let error as ContractError {
            #expect(error.message.contains(fragment), "\(error.message)")
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    /// 2026-11-11 에 androidAdv 와 peer 사이에 scanTime(CANDIDATE-36c)이 들어왔다
    @Test func androidAdvIsAnExtensionLaneBetweenAndroidMtuAndScanTime() {
        let order = Lane.allCases
        #expect(order.firstIndex(of: .androidAdv)! == order.firstIndex(of: .androidMtu)! + 1)
        #expect(order.firstIndex(of: .scanTime)! == order.firstIndex(of: .androidAdv)! + 1)
        #expect(Lane.androidAdv.isExtension)
    }

    @Test func androidAdvMergesConsecutiveDuplicates() {
        var log = ContractLog()
        for entry in ["none", "none", "ext 1M 2M 3 Complete 120", "ext 1M 2M 3 Complete 120", "none"] {
            log.append(entry, to: .androidAdv)
        }
        #expect(log[.androidAdv] == ["none", "ext 1M 2M 3 Complete 120", "none"])
    }

    @Test func extendedAdvertisingIsAcceptedOnAndroidOnlyStartScan() throws {
        let s = try Self.parse(
            platforms: Self.android,
            steps: #"{ "call": "startScan", "extendedAdvertising": true }, { "await": "androidAdv", "is": "ext *" }, { "call": "stopScan" }"#,
            expect: #"{ "androidAdv": ["none", "ext *"] }"#
        )
        guard case .call(let scan) = s.steps[0], case .wait(let wait) = s.steps[1] else {
            Issue.record("unexpected steps")
            return
        }
        #expect(scan.action == .startScan(.none), "값은 담지 않는다")
        #expect(wait.condition == .value(.androidAdv, pattern: "ext *"))
    }

    @Test func extendedAdvertisingRules() {
        Self.rejects(platforms: nil, steps: #"{ "call": "startScan", "extendedAdvertising": true }"#, "exactly [\"android\"]")
        Self.rejects(platforms: #"["android", "ios"]"#, steps: #"{ "call": "startScan", "extendedAdvertising": false }"#, "exactly [\"android\"]")
        Self.rejects(platforms: Self.android, steps: #"{ "call": "startScan", "extendedAdvertising": "true" }"#, "extendedAdvertising")
        Self.rejects(platforms: Self.android, steps: #"{ "call": "stopScan", "extendedAdvertising": true }"#, "extendedAdvertising")
    }

    @Test func extAdvReadsMsWithinRange() throws {
        for ms in [1, 60_000] {
            let s = try Self.parse(platforms: Self.android, steps: Self.ready + #", { "device": "extAdv", "ms": \#(ms) }"#)
            #expect(s.steps[2] == .device(.extAdv(ms: ms)))
        }
        #expect(DeviceEvent.extAdv(ms: 1).name == "extAdv")
    }

    @Test func extAdvRules() {
        for ms in [0, 60_001] {
            Self.rejects(platforms: Self.android, steps: Self.ready + #", { "device": "extAdv", "ms": \#(ms) }"#, "1...60000")
        }
        Self.rejects(platforms: nil, steps: Self.ready + #", { "device": "extAdv", "ms": 1000 }"#, "exactly [\"android\"]")
        Self.rejects(platforms: #"["android", "ios"]"#, steps: Self.ready + #", { "device": "extAdv", "ms": 1000 }"#, "exactly [\"android\"]")
        Self.rejects(platforms: Self.android, steps: Self.ready + #", { "device": "extAdv" }"#, "ms")
    }

    @Test func androidAdvLaneRules() {
        Self.rejects(platforms: nil, steps: #"{ "call": "startScan" }"#, expect: #"{ "androidAdv": ["none"] }"#, "expect.androidAdv")
        Self.rejects(platforms: #"["ios"]"#, steps: #"{ "call": "startScan" }"#, expect: #"{ "androidAdv": ["none"] }"#, "expect.androidAdv")
        Self.rejects(platforms: Self.android, steps: #"{ "call": "startScan" }, { "await": "androidAdv", "is": "ext *" }"#, "needs lane \"androidAdv\" in expect")
        Self.rejects(
            platforms: Self.android,
            steps: #"{ "call": "startScan" }, { "await": "androidAdv", "count": 1 }"#,
            expect: #"{ "androidAdv": [] }"#,
            "count"
        )
    }
}
