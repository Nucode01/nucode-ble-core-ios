import BleContract
import Foundation
import Testing

/// `scanTime` 레인(CANDIDATE-36c): 규칙과 엔진 배선
struct ScanTimeLaneTests {
    static func values(_ times: [Int64]) -> [String] {
        var lane = ScanTimeLane()
        return times.map { lane.record($0) }
    }

    @Test func oneResultStaysNone() {
        #expect(ScanTimeLane().value == "none")
        #expect(Self.values([42]) == ["none"])
    }

    @Test func positiveDiffIsOkAndZeroIsFlat() {
        #expect(Self.values([5, 5, 5]) == ["none", "flat", "flat"])
        #expect(Self.values([5, 5, 9]) == ["none", "flat", "ok"])
        #expect(Self.values([5, 9, 9]) == ["none", "ok", "ok"], "0 차이는 ok 를 지우지 않는다")
    }

    @Test func negativeDiffIsBackAndSticks() {
        #expect(Self.values([5, 9, 3, 10, 11]) == ["none", "ok", "back", "back", "back"])
        #expect(Self.values([5, 5, 4]) == ["none", "flat", "back"])
    }

    // MARK: 엔진 배선 (FakeBackend 는 startScan 마다 대상 결과 둘을 낸다)

    func run(_ steps: String, expect: String, scanTimes: [Int64]) async throws -> ScenarioReport {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: steps, expect: expect))
        let report = await ScenarioEngine(backend: FakeBackend(scanTimes: scanTimes), clock: ScenarioEngineTests.clock).run(scenario)
        report.lines(platform: "fake").forEach { print($0) }
        return report
    }

    static let twoScans = """
        { "call": "startScan" }, { "sleep": 50 }, { "call": "stopScan" },
        { "call": "startScan" }, { "sleep": 50 }, { "call": "stopScan" }
        """

    @Test(.needsContract) func recordedWithOnlyScanTimeInExpectAndMergesRepeats() async throws {
        let report = try await run(Self.twoScans, expect: #"{ "scanTime": ["none", "ok"] }"#, scanTimes: [1, 2, 3, 4])
        #expect(report.verdict == .pass)
        #expect(report.log[.scanTime] == ["none", "ok"])
    }

    @Test(.needsContract) func notResetAtStartScan() async throws {
        let report = try await run(Self.twoScans, expect: #"{ "scanTime": ["none", "flat", "ok"] }"#, scanTimes: [5, 5, 9, 9])
        #expect(report.log[.scanTime] == ["none", "flat", "ok"])
        #expect(report.verdict == .pass)
    }

    @Test(.needsContract) func decreaseInsideOneScanIsBack() async throws {
        let report = try await run(Self.twoScans, expect: #"{ "scanTime": ["none", "back"] }"#, scanTimes: [9, 3, 10, 11])
        #expect(report.log[.scanTime] == ["none", "back"])
    }

    @Test(.needsContract) func awaitIsOkAndFoundStaysFirstPerScan() async throws {
        let report = try await run("""
            { "call": "startScan" }, { "await": "found", "count": 1 }, { "call": "stopScan" },
            { "call": "startScan" }, { "await": "found", "count": 2 }, { "await": "scanTime", "is": "ok" }, { "call": "stopScan" }
            """, expect: #"{ "found": ["probe", "probe"], "scanTime": ["none", "?flat", "ok"] }"#, scanTimes: [])
        #expect(report.verdict == .pass)
    }

    @Test(.needsContract) func droppedWhenNotInExpect() async throws {
        let report = try await run(Self.twoScans, expect: #"{ "result": ["startScan ok", "stopScan ok", "startScan ok", "stopScan ok"] }"#, scanTimes: [1, 2, 3, 4])
        #expect(report.log[.scanTime].isEmpty)
    }
}
