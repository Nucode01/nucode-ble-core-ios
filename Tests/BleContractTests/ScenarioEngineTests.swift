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
    private var adapter = AdapterValue.ready
    private var scanning = false
    private var closed = false
    private var rxBytes = 0
    private var connected = false
    /// 취소가 백엔드 호출까지 닿은 read 수(cancel 단계 시험)
    private(set) var cancelledReads = 0
    /// 각본: 스캔 결과를 내는 기기 수(대상 기기 결과가 여러 번 와도 첫 결과 하나만 남아야 한다)
    static let allSymbols = ["nus.rx", "nus.tx", "probe.control", "probe.value"]

    init(_ script: Script = .normal) {
        self.script = script
    }

    func attach(_ observer: ScenarioObserver) {
        self.observer = observer
        observer.activeSubscriptions([])
        observer.adapter(.ready)
        observer.scan("Idle")
        observer.services([String]())
        observer.properties([:])
    }

    func connect(autoReconnect: Bool) -> CallOutcome {
        guard let observer else { return .failed(code: "NOT_ATTACHED") }
        guard !closed else { return .failed(code: "CLIENT_CLOSED") }
        guard adapter == .ready else { return .failed(code: "ADAPTER_NOT_READY") }
        connected = true
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
                observer.services(Self.allSymbols)
                observer.properties(PropertiesLaneTests.probeProperties)
                observer.state("Configuring")
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
            do {
                try await Task.sleep(for: .seconds(3600))
            } catch {
                cancelledReads += 1
                throw error
            }
        }
        return .ok
    }

    func write(_ char: Characteristic, bytes: [UInt8], withResponse: Bool, chunking: WriteChunking) -> CallOutcome {
        if chunking == .disabled, bytes.count > 20 { return .failed(code: "VALUE_TOO_LONG") }
        if char.symbol == "nus.rx" { rxBytes += bytes.count }
        return .ok
    }

    func startScan(filter: ScanFilter) -> CallOutcome {
        guard !closed else { return .failed(code: "CLIENT_CLOSED") }
        scanning = true
        observer?.scan("Scanning")
        // 같은 기기가 여러 번 보고돼도 창의 첫 결과만 남는다
        let observer = observer
        Task {
            try? await Task.sleep(for: .milliseconds(1))
            observer?.scanResultForTarget()
            observer?.scanResultForTarget()
        }
        return .ok
    }

    func stopScan() -> CallOutcome {
        scanning = false
        observer?.scan("Idle")
        return .ok
    }

    func snapshot() -> ClientSnapshot {
        // 러너는 첫 단계 전에 대상 기기의 세션을 얻으므로(README §단계 snapshot) 연결 전에도 세션이 있다
        let session = connected
            ? ClientSnapshot.Session(isTarget: true, state: "Ready", subscriptions: Array(subscribed))
            : ClientSnapshot.Session(isTarget: true, state: "Disconnected(Initial)", subscriptions: [])
        let sessions = [session]
        return ClientSnapshot(adapter: adapter, scanning: scanning, sessions: sessions)
    }

    func close() -> CallOutcome {
        closed = true
        observer?.state("Disconnected(ClientClosed)")
        return .ok
    }

    func rxCheck() -> String { "\(rxBytes) ok" }

    func setAdapter(_ value: AdapterValue) {
        adapter = value
        observer?.adapter(value)
        if value == .poweredOff, scanning {
            scanning = false
            observer?.scan("Idle(Failed:ADAPTER_OFF)")
        }
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
        case .readNotify, .rxCheck:
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
        // 러너 자체 시험이라 플랫폼 이름을 fake 로 남긴다. ios 로 쓰면 4단계 게이트가 라이브러리 결과로 오인한다
        report.lines(platform: "fake").forEach { print($0) }
        return report
    }

    @Test func connectReadyDisconnectPasses() async throws {
        let report = await run(try Contract.dir.loadScenario(id: "connect-ready-disconnect"))
        #expect(report.verdict == .pass)
        #expect(report.log[.state] == ["Connecting", "DiscoveringServices", "Configuring", "Ready", "Disconnecting", "Disconnected(Requested)"])
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
            """, expect: #"{ "result": ["connect ok", "read probe.value ok"], "state": ["Connecting", "*", "Configuring", "Ready"] }"#))
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

    @Test func cancelRecordsCancelledAndCancelsTheCall() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: """
            { "call": "connect" },
            { "await": "state", "is": "Ready" },
            { "call": "read", "char": "probe.value", "async": true, "name": "r", "timeoutMs": 1000 },
            { "sleep": 50 },
            { "cancel": "r" },
            { "await": "result", "name": "r" },
            { "sleep": 2000 }
            """, expect: #"{ "result": ["connect ok", "read probe.value cancelled"] }"#))
        let backend = FakeBackend(.hangingRead)
        let report = await ScenarioEngine(backend: backend, clock: Self.clock).run(scenario)
        report.lines(platform: "fake").forEach { print($0) }
        // 취소한 호출은 시간 초과로 보지 않는다
        #expect(report.verdict == .pass)
        #expect(await backend.cancelledReads == 1)
    }

    @Test func cancelAfterCompletionAddsNothing() async throws {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: """
            { "call": "connect" },
            { "await": "state", "is": "Ready" },
            { "call": "read", "char": "probe.value", "async": true, "name": "r" },
            { "await": "result", "name": "r" },
            { "cancel": "r" }
            """, expect: #"{ "result": ["connect ok", "read probe.value ok"] }"#))
        let report = await run(scenario)
        #expect(report.verdict == .pass)
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

struct ExtensionLaneTests {
    func run(_ steps: String, expect: String) async throws -> ScenarioReport {
        let scenario = try Contract.scenario(LoaderRejectionTests.scenario(steps: steps, expect: expect))
        let report = await ScenarioEngine(backend: FakeBackend(), clock: ScenarioEngineTests.clock).run(scenario)
        report.lines(platform: "fake").forEach { print($0) }
        return report
    }

    @Test func extensionLanesAreDroppedWhenNotInExpect() async throws {
        let report = try await run("""
            { "call": "startScan" }, { "sleep": 50 }, { "call": "stopScan" },
            { "call": "connect" }, { "await": "state", "is": "Ready" }
            """, expect: #"{ "result": ["startScan ok", "stopScan ok", "connect ok"] }"#)
        #expect(report.verdict == .pass)
        for lane in Lane.allCases where lane.isExtension {
            #expect(report.log[lane].isEmpty, "\(lane)")
        }
        #expect(!report.lines().contains { $0.contains("|scan|") || $0.contains("|adapter|") })
    }

    @Test func scanLanesAndFoundFirstResultPerScan() async throws {
        let report = try await run("""
            { "call": "startScan", "filter": { "name": "Nordic_UART_Service" } },
            { "await": "found", "count": 1 },
            { "call": "stopScan" },
            { "call": "startScan" },
            { "await": "found", "count": 2 },
            { "call": "stopScan" }
            """, expect: #"{ "scan": ["Idle", "Scanning", "Idle", "Scanning", "Idle"], "found": ["probe", "probe"], "adapter": ["Ready"] }"#)
        #expect(report.verdict == .pass)
        #expect(report.log[.scan] == ["Idle", "Scanning", "Idle", "Scanning", "Idle"])
        #expect(report.log[.found] == ["probe", "probe"])
    }

    @Test func servicesLaneAndOrderOfContractLines() async throws {
        let report = try await run("""
            { "call": "connect" }, { "await": "state", "is": "Ready" },
            { "call": "write", "char": "nus.rx", "pattern": 1024 }, { "sleep": 10 },
            { "device": "rxCheck" }
            """, expect: """
            { "peer": ["rx 1024 ok"], "services": ["{}", "{nus.rx,nus.tx,probe.control,probe.value}"], "adapter": ["Ready"], "scan": ["Idle"], "found": [] }
            """)
        #expect(report.verdict == .pass)
        let lanes = report.lines(platform: "fake").compactMap { $0.split(separator: "|").dropFirst(3).first.map(String.init) }
        let order = Lane.allCases.map(\.rawValue) + ["verdict"]
        let ranks = lanes.map { order.firstIndex(of: $0)! }
        #expect(ranks == ranks.sorted())
        #expect(lanes.contains("peer") && lanes.contains("services"))
    }

    @Test func adapterStepAndWaitAndFailure() async throws {
        let report = try await run("""
            { "adapter": "PoweredOff" }, { "await": "adapter", "is": "PoweredOff" },
            { "call": "connect" },
            { "call": "startScan" },
            { "adapter": "Ready" }
            """, expect: #"{ "adapter": ["Ready", "PoweredOff", "Ready"], "result": ["connect fail ADAPTER_NOT_READY", "startScan ok"], "scan": ["Idle", "Scanning"] }"#)
        #expect(report.verdict == .pass)

        let failing = try await run(#"{ "await": "adapter", "is": "Resetting", "timeoutMs": 100 }"#, expect: #"{ "adapter": ["Ready"] }"#)
        #expect(failing.verdict == .fail(reason: "step[0] await adapter Resetting: timed out after 100ms"))
    }

    @Test func adapterOffWhileScanningFailsScan() async throws {
        let report = try await run("""
            { "call": "startScan" }, { "adapter": "PoweredOff" }
            """, expect: #"{ "scan": ["Idle", "Scanning", "Idle(Failed:*)"] }"#)
        #expect(report.verdict == .pass)
    }

    @Test func snapshotResultLine() async throws {
        let report = try await run("""
            { "call": "snapshot" },
            { "call": "connect" }, { "await": "state", "is": "Ready" },
            { "call": "subscribe", "char": "probe.value" },
            { "call": "snapshot" }
            """, expect: """
            { "result": ["snapshot ok adapter=Ready scanning=false sessions=[probe:Disconnected(Initial):{}]", "connect ok", "subscribe probe.value ok",
                         "snapshot ok adapter=Ready scanning=false sessions=[probe:Ready:{probe.value}]"] }
            """)
        #expect(report.verdict == .pass, "\(report.log[.result])")
    }

    @Test func closeThenCallsFail() async throws {
        let report = try await run("""
            { "call": "connect" }, { "await": "state", "is": "Ready" },
            { "call": "close" }, { "call": "startScan" }
            """, expect: #"{ "result": ["connect ok", "close ok", "startScan fail CLIENT_CLOSED"], "state": ["*", "*", "*", "Ready", "Disconnected(ClientClosed)"] }"#)
        #expect(report.verdict == .pass, "\(report.log[.result]) \(report.log[.state])")
    }

    @Test func peerMismatchFailsJudgment() async throws {
        let report = try await run("""
            { "call": "connect" }, { "await": "state", "is": "Ready" }, { "device": "rxCheck" }
            """, expect: #"{ "peer": ["rx 1024 ok"] }"#)
        #expect(report.verdict == .fail(reason: "mismatch: peer"))
    }

    @Test func rxReplyShape() {
        #expect(ScenarioEngine<FakeBackend>.isRxReply("4096 ok"))
        #expect(ScenarioEngine<FakeBackend>.isRxReply("0 bad"))
        #expect(!ScenarioEngine<FakeBackend>.isRxReply("ok"))
        #expect(!ScenarioEngine<FakeBackend>.isRxReply("12 fine"))
        #expect(!ScenarioEngine<FakeBackend>.isRxReply("1 2 ok"))
    }
}
