import BleContract
import Foundation
import Testing

struct ContractFilesTests {
    @Test(.needsContract) func everyScenarioLoads() throws {
        let ids = try Contract.dir.scenarioIds()
        #expect(!ids.isEmpty)
        for id in ids {
            #expect(throws: Never.self, "\(id)") { try Contract.dir.loadScenario(id: id) }
        }
    }

    @Test(.needsContract) func everyPeripheralLoads() throws {
        let names = try Contract.dir.peripheralNames()
        #expect(names.contains("probe"))
        for name in names {
            #expect(throws: Never.self, "\(name)") { try Contract.dir.loadPeripheral(named: name) }
        }
    }

    /// Android 전용 시나리오(CANDIDATE-31)는 읽히지만 iOS 실행 대상(`platforms.contains(.ios)`)이 아니다
    @Test(.needsContract) func androidOnlyScenarioIsNotAnIosTarget() throws {
        let s = try Contract.dir.loadScenario(id: "scan-exposes-raw-advertisement")
        #expect(s.platforms == [.android])
        #expect(!s.platforms.contains(.ios))
        #expect(s.expect[.adTypes]?.last == "{01,07,09}")
    }

    @Test(.needsContract) func adTypesLaneInDiffIgnoreIsAccepted() throws {
        let s = try Contract.scenario(LoaderRejectionTests.scenario(
            expect: #"{ "adTypes": [] }"#,
            extra: #", "diffIgnore": ["adTypes|?{01,09}"]"#
        ))
        #expect(s.diffIgnore.count == 1)
    }

    @Test(.needsContract) func defaultsAreFilledIn() throws {
        let s = try Contract.dir.loadScenario(id: "connect-ready-disconnect")
        #expect(s.platforms == [.android, .ios])
        #expect(s.runsOn == [.sim, .device])
        #expect(s.diffIgnore.isEmpty)
        guard case .call(let connect) = s.steps[0] else {
            Issue.record("first step is not a call")
            return
        }
        #expect(connect.action == .connect(autoReconnect: false))
        #expect(connect.timeoutMs == 15_000)
        #expect(connect.asyncName == nil)
        #expect(s.steps[3] == .wait(AwaitStep(condition: .state(pattern: "Disconnected(*)"), timeoutMs: 15_000)))
    }

    @Test(.needsContract) func probeProfile() throws {
        let probe = try Contract.probe()
        #expect(probe.advertisedName == "Nordic_UART_Service")
        #expect(probe.characteristics["probe.control"]?.runnerOnly == true)
        #expect(probe.characteristics["probe.value"]?.properties == ["read", "notify"])
    }

    @Test(.needsContract) func matchCases() throws {
        let cases = try Contract.dir.loadMatchCases()
        #expect(!cases.isEmpty)
        for c in cases {
            #expect(ContractMatcher.matches(expected: c.expected, actual: c.actual) == c.match, "\(c)")
        }
    }

    @Test(.needsContract) func loadCasesMatchTheirValidity() throws {
        let probe = try Contract.probe()
        let cases = try Contract.dir.loadLoadCases()
        #expect(cases.filter { $0.kind == .scenario }.count >= 43)
        #expect(cases.filter { $0.kind == .peripheral }.count >= 7)
        for c in cases {
            let error = c.attempt(probe: probe)
            #expect((error == nil) == c.valid, "\(c) -> \(error?.message ?? "accepted")")
        }
    }

    @Test(.needsContract) func probeServices() throws {
        let probe = try Contract.probe()
        #expect(probe.services["nus"]?.advertised == true)
        #expect(probe.services["probe"]?.advertised == false)
        #expect(probe.characteristics["probe.control"]?.properties == ["read", "write"])
        #expect(probe.characteristicSymbols == ["nus.rx", "nus.tx", "probe.control", "probe.value"])
    }

    @Test func locateHonorsEnvironment() {
        let root = URL(fileURLWithPath: "/work/ios")
        #expect(ContractDirectory.locate(packageRoot: root, environment: [:]).url.path == "/work/contract")
        #expect(ContractDirectory.locate(packageRoot: root, environment: ["BLE_CONTRACT_DIR": "/elsewhere/contract"]).url.path == "/elsewhere/contract")
    }

    @Test func absentOnlyWithoutVariableAndFolder() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = work.appendingPathComponent("ios", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let missing = ["BLE_CONTRACT_DIR": work.appendingPathComponent("none").path]

        #expect(ContractDirectory.isAbsent(packageRoot: root, environment: [:]))
        #expect(ContractDirectory.isAbsent(packageRoot: root, environment: ["BLE_CONTRACT_DIR": ""]))
        #expect(!ContractDirectory.isAbsent(packageRoot: root, environment: missing))
        try FileManager.default.createDirectory(at: work.appendingPathComponent("contract"), withIntermediateDirectories: true)
        #expect(!ContractDirectory.isAbsent(packageRoot: root, environment: [:]))
    }
}
