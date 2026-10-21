import BleContract
import Foundation
import Testing

/// MTU·write 한도 형식(CANDIDATE-33·CANDIDATE-5): connect 의 `requestedMtu`, `writeLimits`·`androidMtu` 레인, iOS 미구현 draft 판정
@Suite(.needsContract)
struct WriteLimitsFormatTests {
    static let android = #", "platforms": ["android"]"#

    static func connect(mtu: String, platforms: String = android) -> String {
        LoaderRejectionTests.scenario(
            steps: #"{ "call": "connect", "requestedMtu": \#(mtu) }"#,
            extra: platforms
        )
    }

    @Test(arguments: ["23", "517"])
    func requestedMtuInRangeIsRead(mtu: String) throws {
        _ = try Contract.scenario(Self.connect(mtu: mtu))
    }

    @Test(arguments: ["22", "518", "64.5", #""65""#, "true"])
    func requestedMtuOutOfRangeOrNotIntegerIsRejected(mtu: String) {
        #expect(throws: ContractError.self) { try Contract.scenario(Self.connect(mtu: mtu)) }
    }

    @Test(arguments: ["", #", "platforms": ["ios"]"#, #", "platforms": ["android", "ios"]"#])
    func requestedMtuNeedsAndroidOnlyPlatforms(platforms: String) {
        #expect(throws: ContractError.self) { try Contract.scenario(Self.connect(mtu: "65", platforms: platforms)) }
    }

    @Test func requestedMtuOutsideConnectIsRejected() {
        let json = LoaderRejectionTests.scenario(
            steps: #"{ "call": "connect" }, { "call": "disconnect", "requestedMtu": 65 }"#,
            expect: #"{ "result": ["connect ok", "disconnect ok"] }"#,
            extra: Self.android
        )
        #expect(throws: ContractError.self) { try Contract.scenario(json) }
    }

    @Test(arguments: [("writeLimits", "*/*"), ("androidMtu", "65")])
    func valueLanesAreAwaitedWithIs(lane: String, pattern: String) throws {
        let s = try Contract.scenario(LoaderRejectionTests.scenario(
            steps: #"{ "call": "connect" }, { "await": "\#(lane)", "is": "\#(pattern)" }"#,
            expect: #"{ "\#(lane)": [] }"#
        ))
        guard case .wait(let wait) = s.steps[1], case .value(let awaited, let p) = wait.condition else {
            Issue.record("not a value await")
            return
        }
        #expect(awaited.rawValue == lane)
        #expect(p == pattern)
    }

    @Test(arguments: ["writeLimits", "androidMtu"])
    func valueLanesRejectCount(lane: String) {
        let json = LoaderRejectionTests.scenario(
            steps: #"{ "call": "connect" }, { "await": "\#(lane)", "count": 1 }"#,
            expect: #"{ "\#(lane)": [] }"#
        )
        #expect(throws: ContractError.self) { try Contract.scenario(json) }
    }

    @Test func valueLanesMergeConsecutiveDuplicates() {
        var log = ContractLog()
        for entry in ["null", "null", "62/62", "62/62", "null"] { log.append(entry, to: .writeLimits) }
        for entry in ["null", "65", "65"] { log.append(entry, to: .androidMtu) }
        #expect(log[.writeLimits] == ["null", "62/62", "null"])
        #expect(log[.androidMtu] == ["null", "65"])
    }

    @Test func writeLimitsRenderAsPairOrNull() {
        #expect(ContractLog.renderWriteLimits((withResponse: 512, withoutResponse: 62)) == "512/62")
        #expect(ContractLog.renderWriteLimits(nil) == "null")
    }

    @Test func pendingIosSupportNamesTheMissingFeature() throws {
        // iOS 코어가 writeLimits 를 구현해 write-limits draft 는 더 이상 기다리지 않는다
        for id in ["write-limits-ready-and-disconnect", "write-limits-across-recovery"] {
            let s = try Contract.dir.loadScenario(id: id)
            #expect(s.expect[.writeLimits] != nil, "\(id)")
            #expect(s.pendingIosSupport == nil, "\(id)")
            #expect(s.platforms.contains(.ios), "\(id)")
        }
        for id in ["descriptors-discovered", "descriptor-read-write", "descriptor-read-during-link-loss"] {
            #expect(try Contract.dir.loadScenario(id: id).pendingIosSupport == "CANDIDATE-32 descriptor", "\(id)")
        }
        for id in ["connect-requested-mtu", "connect-requested-mtu-conflict"] {
            #expect(try Contract.dir.loadScenario(id: id).platforms == [.android], "\(id)")
        }
        #expect(try Contract.dir.loadScenario(id: "connect-ready-disconnect").pendingIosSupport == nil)
    }

    @Test func pendingIosSupportIsOnlyForDrafts() throws {
        let json = LoaderRejectionTests.scenario(
            steps: #"{ "call": "connect" }, { "await": "writeLimits", "is": "*/*" }"#,
            expect: #"{ "writeLimits": [], "descriptors": [] }"#
        )
        #expect(try Contract.scenario(json).pendingIosSupport == "CANDIDATE-32 descriptor")
        let frozen = json.replacingOccurrences(of: #""status": "draft""#, with: #""status": "frozen""#)
        #expect(try Contract.scenario(frozen).pendingIosSupport == nil)
    }
}
