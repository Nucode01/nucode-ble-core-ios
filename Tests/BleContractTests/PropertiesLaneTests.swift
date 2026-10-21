import BleContract
import Foundation
import Testing

/// `properties` 레인(CANDIDATE-30): 줄 모양, 중복 합침, 출력 순서, `is` 로 기다릴 수 없음
struct PropertiesLaneTests {
    /// probe 기기 정의와 같은 값. 가짜 백엔드가 연결 뒤 이 값을 낸다
    static let probeProperties: [String: Set<String>] = [
        "nus.rx": ["write", "writeWithoutResponse"],
        "nus.tx": ["notify"],
        "probe.control": ["read", "write"],
        "probe.value": ["read", "notify"],
    ]
    static let probeLine = "{nus.rx=write+writeWithoutResponse,nus.tx=notify,probe.control=read+write,probe.value=notify+read}"

    @Test func renderSortsNamesAndProperties() {
        #expect(ContractLog.renderProperties([:]) == "{}")
        #expect(ContractLog.renderProperties(Self.probeProperties) == Self.probeLine)
        #expect(ContractLog.renderProperties(["b": ["notify"], "a": []]) == "{a=,b=notify}")
        #expect(ContractLog.renderProperties(["x": ["writeWithoutResponse", "indicate", "write"]]) == "{x=indicate+write+writeWithoutResponse}")
    }

    @Test(.needsContract) func probeDefinitionRendersTheContractLine() throws {
        let probe = try Contract.probe()
        let entries = probe.characteristics.mapValues { Set($0.properties) }
        #expect(ContractLog.renderProperties(entries) == Self.probeLine)
        let scenario = try Contract.dir.loadScenario(id: "services-expose-properties")
        #expect(scenario.expect[.properties]?.last == Self.probeLine)
    }

    @Test func consecutiveDuplicatesMerge() {
        var log = ContractLog()
        log.append("{}", to: .properties)
        log.append("{}", to: .properties)
        log.append(Self.probeLine, to: .properties)
        log.append(Self.probeLine, to: .properties)
        #expect(log[.properties] == ["{}", Self.probeLine])
    }

    @Test func laneOrderIsServicesPropertiesAdTypesPeer() {
        let order = Lane.allCases
        #expect(order.firstIndex(of: .properties)! == order.firstIndex(of: .services)! + 1)
        #expect(order.firstIndex(of: .adTypes)! == order.firstIndex(of: .properties)! + 1)
        #expect(order.firstIndex(of: .peer)! == order.firstIndex(of: .adTypes)! + 1)
        #expect(Lane.properties.isExtension)
        #expect(Lane.adTypes.isExtension)
    }

    @Test(.needsContract) func recordedWhenInExpect() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(
            steps: #"{ "call": "connect" }, { "await": "state", "is": "Ready" }, { "sleep": 10 }"#,
            expect: #"{ "result": ["connect ok"], "properties": ["{}", "\#(Self.probeLine)"], "services": ["{}", "{nus.rx,nus.tx,probe.control,probe.value}"] }"#
        ))
        let report = await ScenarioEngine(backend: FakeBackend(), clock: ScenarioEngineTests.clock).run(scenario)
        #expect(report.verdict == .pass)
        #expect(report.log[.properties] == ["{}", Self.probeLine])
        let lanes = report.lines(platform: "fake").compactMap { $0.split(separator: "|").dropFirst(3).first.map(String.init) }
        #expect(lanes.lastIndex(of: "services")! < lanes.firstIndex(of: "properties")!)
    }

    @Test(.needsContract) func awaitingPropertiesIsRejected() {
        #expect(throws: ContractError.self) {
            try Contract.scenario(LoaderRejectionTests.scenario(
                steps: #"{ "call": "connect" }, { "await": "properties", "is": "{*}" }"#,
                expect: #"{ "properties": [] }"#
            ))
        }
    }
}
