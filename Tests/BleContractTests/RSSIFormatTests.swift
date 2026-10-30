import BleContract
import Foundation
import Testing

/// FakeBackend 의 RSSI 호출. 늘 -58 이다(진입 검사는 실제 라이브러리 시험이 본다)
extension FakeBackend {
    func readRssi() -> CallOutcome {
        .rssiRead(-58)
    }
}

/// RSSI 호출 형식(CANDIDATE-34): `readRssi`(추가 키 없음), 결과 줄 `readRssi ok <dBm>`
@Suite(.needsContract)
struct RSSIFormatTests {
    static let ready = #"{ "call": "connect" }, { "await": "state", "is": "Ready" }"#

    @Test func readRssiTakesOnlyTheCommonKeys() throws {
        let s = try Contract.scenario(LoaderRejectionTests.scenario(
            steps: Self.ready + #", { "call": "readRssi" }, { "call": "readRssi", "async": true, "name": "r1", "timeoutMs": 6000 }"#
        ))
        guard case .call(let plain) = s.steps[2], case .call(let named) = s.steps[3] else {
            Issue.record("readRssi steps are not calls")
            return
        }
        #expect(plain.action == .readRssi)
        #expect(plain.action.label == "readRssi")
        #expect(named.asyncName == "r1")
        #expect(named.timeoutMs == 6000)
    }

    @Test(arguments: [#""char": "probe.value""#, #""desc": "probe.control/cud""#, #""hex": "01""#])
    func readRssiRejectsExtraKeys(extra: String) {
        #expect(throws: ContractError.self) {
            try Contract.scenario(LoaderRejectionTests.scenario(steps: Self.ready + #", { "call": "readRssi", "# + extra + " }"))
        }
    }

    @Test func resultLineCarriesDecimalDBm() {
        #expect(CallOutcome.rssiRead(-58).rendered == "ok -58")
        #expect(CallOutcome.rssiRead(127).rendered == "ok 127")
    }

    @Test func engineWritesRssiResultLines() async throws {
        let s = try Contract.scenario(LoaderRejectionTests.scenario(
            steps: Self.ready + #", { "call": "readRssi" }"#,
            expect: #"{ "result": ["connect ok", "readRssi ok -*"] }"#
        ))
        let report = await ScenarioEngine(backend: FakeBackend(), clock: ScenarioEngineTests.clock).run(s)
        #expect(report.verdict == .pass)
    }

    @Test func rssiScenariosRunOnBothPlatforms() throws {
        for id in ["read-rssi-when-ready", "read-rssi-during-write", "read-rssi-cancel-then-read"] {
            let scenario = try Contract.dir.loadScenario(id: id)
            #expect(scenario.platforms.contains(.ios), "\(id)")
            #expect(scenario.runsOn.contains(.sim), "\(id)")
        }
    }
}
