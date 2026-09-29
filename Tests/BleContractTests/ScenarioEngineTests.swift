import BleContract
import Foundation
import Testing

/// 각본대로 관찰을 내는 가짜 백엔드. 4단계의 실제 백엔드가 낼 관찰 모양을 흉내 낸다
actor FakeBackend: ScenarioBackend {
    enum Script: Sendable {
        case normal
        /// DiscoveringServices 를 건너뛴다(틀린 상태 흐름)
        case skipDiscovery
        /// Connecting 에서 멈춘다
        case neverReady
        /// read 가 끝나지 않는다
        case hangingRead
    }

    let script: Script
    private var observer: ScenarioObserver?
    private var subscribed: Set<String> = []

    init(_ script: Script = .normal) {
        self.script = script
    }

    func attach(_ observer: ScenarioObserver) {
        self.observer = observer
        observer.activeSubscriptions([])
    }

    func connect(autoReconnect: Bool) -> CallOutcome {
        guard let observer else { return .failed(code: "NOT_ATTACHED") }
        observer.state("Connecting")
        // connect 는 연결 시도가 시작되면 반환하고, 나머지 전이는 뒤에 온다
        let script = script
        Task {
            try? await Task.sleep(for: .milliseconds(2))
            switch script {
            case .neverReady:
                return
            case .skipDiscovery:
                observer.state("Ready")
            case .normal, .hangingRead:
                observer.state("DiscoveringServices")
                observer.state("Ready")
            }
        }
        return .ok
    }

    func disconnect() -> CallOutcome {
        observer?.state("Disconnecting")
        observer?.state("Disconnected(Requested)")
        return .ok
    }

    func read(_ char: Characteristic) async throws -> CallOutcome {
        if script == .hangingRead {
            try await Task.sleep(for: .seconds(3600))
        }
        return .ok
    }

    func write(_ char: Characteristic, bytes: [UInt8], withResponse: Bool) -> CallOutcome {
        .ok
    }

    func subscribe(_ char: Characteristic) -> CallOutcome {
        subscribed.insert(char.symbol)
        observer?.activeSubscriptions(subscribed)
        return .ok
    }

    func unsubscribe(_ char: Characteristic) -> CallOutcome {
        subscribed.remove(char.symbol)
        observer?.activeSubscriptions(subscribed)
        return .ok
    }

    func performDeviceEvent(_ event: DeviceEvent) {
        switch event {
        case .notify(let count):
            // 구독 중일 때만 앱에 도착한다
            guard subscribed.contains("probe.value") else { return }
            for _ in 0..<count { observer?.notification("probe.value") }
        case .linkDrop, .linkDropHide:
            observer?.state("Disconnected(Failed:LINK_FAILED)")
        case .readNotify:
            break
        }
    }

    func tearDown() {
        // 기록이 닫힌 뒤라 남지 않아야 한다
        observer?.state("Disconnected(ClientClosed)")
    }
}

struct ScenarioEngineTests {
    /// 시나리오 시간 1ms = 실제 0.01ms. 20초 기다림도 0.2초 안에 끝난다
    static let clock = ContractClock.scaled(0.01)

    func run(_ scenario: Scenario, _ script: FakeBackend.Script = .normal) async -> ScenarioReport {
        let report = await ScenarioEngine(backend: FakeBackend(script), clock: Self.clock).run(scenario)
        report.lines().forEach { print($0) }
        return report
    }

    @Test func connectReadyDisconnectPasses() async throws {
        let report = await run(try Contract.dir.loadScenario(id: "connect-ready-disconnect"))
        #expect(report.verdict == .pass)
        #expect(report.log[.state] == ["Connecting", "DiscoveringServices", "Ready", "Disconnecting", "Disconnected(Requested)"])
        #expect(report.log[.result] == ["connect ok", "disconnect ok"])
        #expect(report.log[.active] == ["{}"])
        #expect(report.lines().last == "CONTRACT|ios|connect-ready-disconnect|verdict|PASS")
        #expect(report.lines().contains("CONTRACT|ios|connect-ready-disconnect|state|Ready"))
    }

    @Test func subscribeNotifyUnsubscribePasses() async throws {
        let report = await run(try Contract.dir.loadScenario(id: "subscribe-notify-unsubscribe"))
        #expect(report.verdict == .pass)
        #expect(report.log[.notify] == ["probe.value", "probe.value", "probe.value"])
        #expect(report.log[.active] == ["{}", "{probe.value}", "{}"])
        #expect(report.log[.result] == ["connect ok", "subscribe probe.value ok", "unsubscribe probe.value ok"])
    }

    @Test func wrongStateSequenceFails() async throws {
        let report = await run(try Contract.dir.loadScenario(id: "connect-ready-disconnect"), .skipDiscovery)
        #expect(report.verdict == .fail(reason: "mismatch: state"))
        #expect(report.lines().last == "CONTRACT|ios|connect-ready-disconnect|verdict|FAIL|mismatch: state")
    }

    @Test func awaitTimeoutFailsAndSkipsRemainingSteps() async throws {
        let report = await run(try Contract.dir.loadScenario(id: "connect-ready-disconnect"), .neverReady)
        #expect(report.verdict == .fail(reason: "step[1] await state Ready: timed out after 20000ms"))
        // disconnect 는 실행되지 않는다
        #expect(report.log[.result] == ["connect ok"])
        #expect(report.log[.state] == ["Connecting"])
    }

    @Test func syncCallTimeoutFailsWithoutResultEntry() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: """
            { "call": "connect" },
            { "await": "state", "is": "Ready" },
            { "call": "read", "char": "probe.value", "timeoutMs": 1000 },
            { "call": "disconnect" }
            """))
        let report = await run(scenario, .hangingRead)
        #expect(report.verdict == .fail(reason: "step[2] call read probe.value: timed out after 1000ms"))
        #expect(report.log[.result] == ["connect ok"])
    }

    @Test func asyncCallAndAwaitResult() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: """
            { "call": "connect", "async": true, "name": "c" },
            { "await": "result", "name": "c" },
            { "await": "state", "is": "Rea*" },
            { "call": "read", "char": "probe.value", "async": true, "name": "r", "timeoutMs": 500 },
            { "sleep": 100 }
            """, expect: #"{ "result": ["connect ok", "read probe.value ok"], "state": ["Connecting", "*", "Ready"] }"#))
        let report = await run(scenario)
        #expect(report.verdict == .pass)
    }

    @Test func asyncCallTimeoutFails() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: """
            { "call": "connect" },
            { "await": "state", "is": "Ready" },
            { "call": "read", "char": "probe.value", "async": true, "name": "r", "timeoutMs": 1000 },
            { "await": "result", "name": "r", "timeoutMs": 5000 }
            """))
        let report = await run(scenario, .hangingRead)
        #expect(report.verdict == .fail(reason: "async call r (read probe.value): timed out after 1000ms"))
    }

    @Test func deviceEventNeedsReady() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: """
            { "call": "connect" },
            { "device": "linkDrop" }
            """))
        let report = await run(scenario)
        #expect(report.verdict == .fail(reason: "step[1] device linkDrop: device events need Ready, last state is Connecting"))
    }

    @Test func observationsAfterCloseAreIgnored() async throws {
        let report = await run(try Contract.dir.loadScenario(id: "link-drop-without-auto-reconnect"))
        #expect(report.verdict == .pass)
        #expect(report.log[.state].last == "Disconnected(Failed:LINK_FAILED)")
    }
}

struct ContractLogTests {
    @Test func activeDedupesConsecutiveValuesOnly() {
        var log = ContractLog()
        log.appendActive([String]())
        log.appendActive([String]())
        log.appendActive(["probe.value", "nus.tx"])
        log.appendActive(["nus.tx", "probe.value"])
        log.appendActive([String]())
        log.append("Ready", to: .state)
        log.append("Ready", to: .state)
        #expect(log[.active] == ["{}", "{nus.tx,probe.value}", "{}"])
        #expect(log[.state] == ["Ready", "Ready"])
    }

    @Test func judgesOnlyListedLanes() {
        var log = ContractLog()
        log.append("connect ok", to: .result)
        log.append("probe.value", to: .notify)
        #expect(log.judge([.result: ["connect ok"]]) == .pass)
        #expect(log.judge([.result: ["connect ok"], .notify: []]) == .fail(reason: "mismatch: notify"))
        #expect(log.judge([.state: ["Ready"], .notify: []]) == .fail(reason: "mismatch: state,notify"))
    }

    @Test func lineFormat() {
        var log = ContractLog()
        log.append("connect ok", to: .result)
        log.append("Connecting", to: .state)
        #expect(log.lines(platform: "ios", scenarioId: "x") == ["CONTRACT|ios|x|state|Connecting", "CONTRACT|ios|x|result|connect ok"])
        #expect(ContractLog.verdictLine(.fail(reason: "r"), platform: "ios", scenarioId: "x") == "CONTRACT|ios|x|verdict|FAIL|r")
    }
}
