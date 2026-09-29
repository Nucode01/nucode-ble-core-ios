import XCTest
@testable import NucodeBleCore

/// 연결 상태 기계 표 시험(contract/states.md §1~§5, 행 id 는 .plans/refactor-R3-*.md 의 C01~C25).
/// 공개 타입에 `Equatable` 이 없어 단계와 할 일을 계약 표기 문자열로 비교한다.
final class ConnectionCoreTests: XCTestCase {
    typealias Core = ConnectionCore

    // MARK: 표기

    private func name(_ phase: ConnectionState) -> String {
        switch phase {
        case .connecting: "Connecting"
        case .discoveringServices: "DiscoveringServices"
        case .configuring: "Configuring"
        case .ready: "Ready"
        case .disconnecting: "Disconnecting"
        case .recovering(let failure): "Recovering(\(failure.code.value))"
        case .disconnected(let reason):
            switch reason {
            case .initial: "Disconnected(Initial)"
            case .requested: "Disconnected(Requested)"
            case .clientClosed: "Disconnected(ClientClosed)"
            case .failed(let failure): "Disconnected(Failed:\(failure.code.value))"
            }
        }
    }

    private func name(_ kind: Core.TimerKind) -> String {
        switch kind {
        case .link: "link"
        case .configuration: "configuration"
        case .cleanup: "cleanup"
        }
    }

    private func name(_ effect: Core.Effect) -> String {
        switch effect {
        case .publish(let phase): "publish(\(name(phase)))"
        case .beginAttempt(let generation, let options, let deadline):
            "beginAttempt(g\(generation),auto=\(options.autoReconnect),deadline=\(deadline.map(String.init) ?? "none"))"
        case .joinAttempt: "joinAttempt"
        case .rejectConnect(let failure): "reject(\(failure.code.value))"
        case .abortAttempt: "abortAttempt"
        case .resolveAttempt: "resolveAttempt"
        case .connectPeripheral: "connectPeripheral"
        case .cancelPeripheralConnection: "cancelPeripheralConnection"
        case .armTimer(let kind, let generation, let ms): "armTimer(\(name(kind)),g\(generation),\(ms))"
        case .cancelTimer(let kind): "cancelTimer(\(name(kind)))"
        case .cancelTimers: "cancelTimers"
        case .startDiscovery(let generation): "startDiscovery(g\(generation))"
        case .cancelDiscovery: "cancelDiscovery"
        case .commitServices: "commitServices"
        case .startConfiguration(let generation): "startConfiguration(g\(generation))"
        case .dropLinkBoundState: "dropLinkBound"
        case .clearSubscriptionIntent: "clearSubscriptionIntent"
        case .openDisconnectWaiter: "openDisconnectWaiter"
        case .awaitDisconnect: "awaitDisconnect"
        case .resolveDisconnectWaiter: "resolveDisconnectWaiter"
        case .diagnostic(let code, _): "diagnostic(\(code.value))"
        case .closeGattState: "closeGattState"
        case .releasePeripheralOnClose: "releasePeripheralOnClose"
        case .closeFlows: "closeFlows"
        }
    }

    private func failure(_ code: FailureCode) -> BLEFailure {
        BLEFailure(code: code, message: code.value)
    }

    // MARK: 장치

    private let auto = ConnectOptions(autoReconnect: true)
    private let manual = ConnectOptions(autoReconnect: false)

    /// 상태 하나를 들고 사건을 먹이는 도구. `fire` 는 그 사건의 할 일 표기를 돌려준다
    private struct Rig {
        var state = Core.State()
        var lastEffects: [Core.Effect] = []

        @discardableResult
        mutating func fire(_ event: Core.Event) -> [Core.Effect] {
            let (next, effects) = Core.step(state, event)
            state = next
            lastEffects = effects
            return effects
        }
    }

    private func rig(_ options: ConnectOptions, upTo phase: String) -> Rig {
        var r = Rig()
        if phase == "Disconnected" { return r }
        r.fire(.connect(options: options, now: 1000))
        if phase == "Attempt" { return r }
        r.fire(.attemptAccepted(generation: 1, now: 1000))
        if phase == "Connecting" { return r }
        r.fire(.linkConnected(sameDevice: true))
        if phase == "DiscoveringServices" { return r }
        r.fire(.discoveryFinished(generation: 1, failure: nil))
        if phase == "Configuring" { return r }
        r.fire(.configurationFinished(generation: 1))
        return r
    }

    private func check(_ id: String, _ r: Rig, phase: String, effects: [String]? = nil, line: UInt = #line) {
        XCTAssertEqual(name(r.state.phase), phase, "\(id) 단계", line: line)
        if let effects {
            XCTAssertEqual(r.lastEffects.map { name($0) }, effects, "\(id) 할 일", line: line)
        }
    }

    private let endLinkFx = ["cancelTimers", "cancelDiscovery", "dropLinkBound"]

    // MARK: 초기·링크 전이

    func test_initialAndLinkTransitions() {
        // C01
        var r = Rig()
        check("C01", r, phase: "Disconnected(Initial)")
        XCTAssertTrue(r.lastEffects.isEmpty, "C01 할 일 없음")

        // C08
        r = rig(manual, upTo: "Connecting")
        r.fire(.linkConnected(sameDevice: true))
        check("C08", r, phase: "DiscoveringServices",
              effects: ["cancelTimer(link)", "publish(DiscoveringServices)", "startDiscovery(g1)"])

        // C09: 서비스 게시가 Configuring 보다 먼저
        r.fire(.discoveryFinished(generation: 1, failure: nil))
        check("C09", r, phase: "Configuring",
              effects: ["commitServices", "publish(Configuring)", "armTimer(configuration,g1,10000)", "startConfiguration(g1)"])

        // C11
        r.fire(.configurationFinished(generation: 1))
        check("C11", r, phase: "Ready", effects: ["cancelTimer(configuration)", "publish(Ready)"])
        XCTAssertTrue(r.state.hasBeenReady, "C11 Ready 에 닿은 적 있음")

        // C10
        r = rig(manual, upTo: "DiscoveringServices")
        r.fire(.discoveryFinished(generation: 1, failure: failure(.serviceDiscoveryFailed)))
        check("C10", r, phase: "Disconnected(Failed:SERVICE_DISCOVERY_FAILED)",
              effects: endLinkFx + ["publish(Disconnected(Failed:SERVICE_DISCOVERY_FAILED))", "resolveDisconnectWaiter", "cancelPeripheralConnection"])
    }

    func test_linkLossAndConnectFailure() {
        // C12: 첫 연결은 auto 여도 Recovering 이 아니다
        for phase in ["Connecting", "DiscoveringServices", "Configuring"] {
            var r = rig(auto, upTo: phase)
            r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
            check("C12", r, phase: "Disconnected(Failed:LINK_FAILED)")
        }
        // C13
        var r = rig(manual, upTo: "Connecting")
        r.fire(.linkFailedToConnect(sameDevice: true, failure: failure(.linkFailed)))
        check("C13", r, phase: "Disconnected(Failed:LINK_FAILED)",
              effects: endLinkFx + ["publish(Disconnected(Failed:LINK_FAILED))", "resolveDisconnectWaiter"])
    }

    // MARK: connect 진입

    func test_connectAdmission() {
        // C02
        var r = rig(manual, upTo: "Disconnected")
        r.fire(.connect(options: manual, now: 1000))
        check("C02", r, phase: "Disconnected(Initial)", effects: ["beginAttempt(g1,auto=false,deadline=16000)"])
        XCTAssertEqual(r.state.generation, 1, "C02 세대+1")
        r = rig(auto, upTo: "Disconnected")
        r.fire(.connect(options: auto, now: 1000))
        check("C02", r, phase: "Disconnected(Initial)", effects: ["beginAttempt(g1,auto=true,deadline=none)"])

        // C03
        r = rig(manual, upTo: "Connecting")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        let generation = r.state.generation
        r.fire(.connect(options: manual, now: 2000))
        check("C03", r, phase: "Disconnecting", effects: ["reject(CONNECT_DURING_DISCONNECT)"])
        XCTAssertEqual(r.state.generation, generation, "C03 세대 그대로")

        // C04
        r = rig(manual, upTo: "Attempt")
        r.fire(.connect(options: auto, now: 1000))
        check("C04", r, phase: "Disconnected(Initial)", effects: ["reject(CONNECTION_OPTIONS_CONFLICT)"])
        r.fire(.connect(options: manual, now: 1000))
        check("C04", r, phase: "Disconnected(Initial)", effects: ["joinAttempt"])

        // C05
        for phase in ["Connecting", "DiscoveringServices", "Configuring", "Ready"] {
            r = rig(manual, upTo: phase)
            r.fire(.connect(options: manual, now: 1000))
            check("C05", r, phase: phase, effects: [])
            r.fire(.connect(options: auto, now: 1000))
            check("C05", r, phase: phase, effects: ["reject(CONNECTION_OPTIONS_CONFLICT)"])
        }
        r = rig(auto, upTo: "Ready")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        check("C05", r, phase: "Recovering(LINK_FAILED)")
        r.fire(.connect(options: auto, now: 1000))
        check("C05", r, phase: "Recovering(LINK_FAILED)", effects: [])
        r.fire(.connect(options: manual, now: 1000))
        check("C05", r, phase: "Recovering(LINK_FAILED)", effects: ["reject(CONNECTION_OPTIONS_CONFLICT)"])
    }

    func test_attemptResolution() {
        // C06
        var r = rig(manual, upTo: "Attempt")
        r.fire(.attemptFailed(generation: 1))
        check("C06", r, phase: "Disconnected(Initial)", effects: ["abortAttempt"])
        XCTAssertNil(r.state.attempt, "C06 시도 정리")
        r.fire(.attemptFailed(generation: 1))
        check("C06", r, phase: "Disconnected(Initial)", effects: [])

        // C07
        r = rig(manual, upTo: "Attempt")
        r.fire(.attemptAccepted(generation: 1, now: 4000))
        check("C07", r, phase: "Connecting",
              effects: ["publish(Connecting)", "connectPeripheral", "armTimer(link,g1,12000)", "resolveAttempt"])
        r = rig(auto, upTo: "Attempt")
        r.fire(.attemptAccepted(generation: 1, now: 4000))
        check("C07", r, phase: "Connecting", effects: ["publish(Connecting)", "connectPeripheral", "resolveAttempt"])
    }

    // MARK: 기한

    func test_deadlines() {
        // C14: link
        var r = rig(manual, upTo: "Connecting")
        r.fire(.timerFired(kind: .link, generation: 1))
        check("C14", r, phase: "Disconnected(Failed:LINK_TIMEOUT)",
              effects: endLinkFx + ["publish(Disconnected(Failed:LINK_TIMEOUT))", "resolveDisconnectWaiter", "cancelPeripheralConnection"])
        // configuration
        r = rig(manual, upTo: "Configuring")
        r.fire(.timerFired(kind: .configuration, generation: 1))
        check("C14", r, phase: "Disconnected(Failed:CONFIGURATION_TIMEOUT)",
              effects: endLinkFx + ["publish(Disconnected(Failed:CONFIGURATION_TIMEOUT))", "resolveDisconnectWaiter", "cancelPeripheralConnection"])
        // 다른 세대·다른 단계의 만료는 무시
        r = rig(manual, upTo: "Connecting")
        r.fire(.timerFired(kind: .link, generation: 2))
        check("C14", r, phase: "Connecting", effects: [])
        r = rig(manual, upTo: "Configuring")
        r.fire(.timerFired(kind: .link, generation: 1))
        check("C14", r, phase: "Configuring", effects: [])
        r = rig(manual, upTo: "Ready")
        r.fire(.timerFired(kind: .configuration, generation: 1))
        check("C14", r, phase: "Ready", effects: [])
    }

    // MARK: 해제·닫힘

    func test_disconnectAndClose() {
        // C15
        var r = rig(manual, upTo: "Ready")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        check("C15", r, phase: "Disconnecting", effects: [
            "openDisconnectWaiter", "clearSubscriptionIntent", "cancelTimers", "cancelDiscovery", "publish(Disconnecting)",
            "dropLinkBound", "cancelPeripheralConnection", "armTimer(cleanup,g1,5000)", "awaitDisconnect",
        ])
        XCTAssertNil(r.state.intent, "C15 의도 지움")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        check("C15", r, phase: "Disconnected(Requested)",
              effects: endLinkFx + ["publish(Disconnected(Requested))", "resolveDisconnectWaiter"])
        // Disconnecting 중 다시 disconnect 는 같은 정리를 기다린다
        r = rig(manual, upTo: "Ready")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        check("C15", r, phase: "Disconnecting", effects: ["awaitDisconnect"])

        // C16: 링크 없음
        r = rig(manual, upTo: "Ready")
        r.fire(.disconnect(hasLinkTarget: false, linked: false))
        check("C16", r, phase: "Disconnected(Requested)", effects: [
            "openDisconnectWaiter", "clearSubscriptionIntent", "cancelTimers", "cancelDiscovery", "publish(Disconnecting)", "dropLinkBound",
            "cancelTimers", "cancelDiscovery", "dropLinkBound", "publish(Disconnected(Requested))", "resolveDisconnectWaiter", "awaitDisconnect",
        ])
        // 붙지 않은 Connecting
        r = rig(manual, upTo: "Connecting")
        r.fire(.disconnect(hasLinkTarget: true, linked: false))
        check("C16", r, phase: "Disconnected(Requested)")
        XCTAssertTrue(r.lastEffects.map { name($0) }.contains("cancelPeripheralConnection"), "C16 취소 요청")
        XCTAssertFalse(r.lastEffects.map { name($0) }.contains("armTimer(cleanup,g1,5000)"), "C16 cleanup 기한 없음")
        // cleanup 기한 만료
        r = rig(manual, upTo: "Ready")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        r.fire(.timerFired(kind: .cleanup, generation: 1))
        check("C16", r, phase: "Disconnected(Requested)", effects: [
            "diagnostic(DISCONNECT_CLEANUP_TIMEOUT)", "cancelTimers", "cancelDiscovery", "dropLinkBound",
            "publish(Disconnected(Requested))", "resolveDisconnectWaiter",
        ])

        // C24
        r = rig(manual, upTo: "Attempt")
        r.fire(.disconnect(hasLinkTarget: false, linked: false))
        check("C24", r, phase: "Disconnected(Initial)", effects: ["clearSubscriptionIntent", "abortAttempt"])
        XCTAssertNil(r.state.attempt, "C24 시도 정리")
        r = rig(auto, upTo: "Ready")
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        XCTAssertTrue(r.state.resumeOnAdapterReady, "C24 준비")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        check("C24", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: ["clearSubscriptionIntent"])
        XCTAssertFalse(r.state.resumeOnAdapterReady, "C24 재연결 해제")

        // C21: 시작 전 시도
        r = rig(manual, upTo: "Attempt")
        r.fire(.close)
        check("C21", r, phase: "Disconnected(Initial)", effects: [
            "abortAttempt", "cancelTimers", "cancelDiscovery", "closeGattState", "releasePeripheralOnClose", "resolveDisconnectWaiter", "closeFlows",
        ])
        XCTAssertEqual(name(Core.snapshotPhase(r.state)), "Disconnected(Initial)", "C21 이미 Disconnected 면 그 값")
        // 열린 단계
        r = rig(manual, upTo: "Ready")
        r.fire(.close)
        XCTAssertEqual(name(Core.snapshotPhase(r.state)), "Disconnected(ClientClosed)", "C21 스냅숏 단계")
        XCTAssertTrue(r.state.closed, "C21 닫힘")
        // 이후 사건 무시, 두 번째 close 무동작
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        check("C21", r, phase: "Ready", effects: [])
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        check("C21", r, phase: "Ready", effects: [])
        r.fire(.close)
        check("C21", r, phase: "Ready", effects: [])
    }

    // MARK: Recovering·어댑터

    func test_recoveringAndAdapter() {
        // C17
        var r = rig(auto, upTo: "Ready")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        check("C17", r, phase: "Recovering(LINK_FAILED)",
              effects: ["cancelTimers", "cancelDiscovery", "publish(Recovering(LINK_FAILED))", "dropLinkBound", "connectPeripheral"])
        r = rig(manual, upTo: "Ready")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        check("C17", r, phase: "Disconnected(Failed:LINK_FAILED)")

        // C18
        r = rig(auto, upTo: "Ready")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        r.fire(.linkConnected(sameDevice: true))
        check("C18", r, phase: "DiscoveringServices",
              effects: ["cancelTimer(link)", "publish(DiscoveringServices)", "startDiscovery(g1)"])
        r.fire(.discoveryFinished(generation: 1, failure: nil))
        check("C18", r, phase: "Configuring")
        r.fire(.configurationFinished(generation: 1))
        check("C18", r, phase: "Ready")
        r = rig(auto, upTo: "Ready")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        r.fire(.linkFailedToConnect(sameDevice: true, failure: failure(.linkFailed)))
        check("C18", r, phase: "Disconnected(Failed:LINK_FAILED)")

        // C19
        let cases: [(AdapterState, String)] = [
            (.poweredOff, "ADAPTER_UNAVAILABLE"), (.resetting, "ADAPTER_UNAVAILABLE"), (.unsupported, "ADAPTER_UNAVAILABLE"),
            (.unauthorized(canRequest: true), "PERMISSION_DENIED"), (.unauthorized(canRequest: false), "PERMISSION_DENIED"),
        ]
        for phase in ["Connecting", "DiscoveringServices", "Configuring", "Ready", "Recovering"] {
            for (adapter, code) in cases {
                r = phase == "Recovering" ? rig(auto, upTo: "Ready") : rig(manual, upTo: phase)
                if phase == "Recovering" { r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed))) }
                r.fire(.adapterChanged(adapter, now: 2000))
                check("C19", r, phase: "Disconnected(Failed:\(code))")
                XCTAssertEqual(r.lastEffects.last.map { name($0) }, "cancelPeripheralConnection", "C19 취소 \(phase)")
            }
        }
        r = rig(manual, upTo: "Ready")
        r.fire(.adapterChanged(.unauthorized(canRequest: true), now: 2000))
        if case .disconnected(.failed(let f)) = r.state.phase {
            XCTAssertEqual(f.retryability, .afterEnvironmentChange, "C19 canRequest")
        } else { XCTFail("C19 단계") }
        r = rig(manual, upTo: "Ready")
        r.fire(.adapterChanged(.unauthorized(canRequest: false), now: 2000))
        if case .disconnected(.failed(let f)) = r.state.phase {
            XCTAssertEqual(f.retryability, .never, "C19 !canRequest")
        } else { XCTFail("C19 단계") }
        r = rig(manual, upTo: "Disconnected")
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        check("C19", r, phase: "Disconnected(Initial)", effects: [])
        r = rig(manual, upTo: "Ready")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        check("C19", r, phase: "Disconnecting", effects: [])

        // C20
        r = rig(auto, upTo: "Ready")
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        r.fire(.adapterChanged(.ready, now: 3000))
        check("C20", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: ["beginAttempt(g2,auto=true,deadline=none)"])
        r.fire(.adapterChanged(.ready, now: 4000))
        check("C20", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: [])
        r = rig(manual, upTo: "Ready")
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        r.fire(.adapterChanged(.ready, now: 3000))
        check("C20", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: [])
        r = rig(auto, upTo: "Ready")
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        r.fire(.disconnect(hasLinkTarget: true, linked: false))
        r.fire(.adapterChanged(.ready, now: 3000))
        check("C20", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: [])

        // C25: 오래된 세대·live 아님
        r = rig(manual, upTo: "Connecting")
        r.fire(.linkConnected(sameDevice: false))
        check("C25", r, phase: "Connecting", effects: [])
        r.fire(.linkDisconnected(sameDevice: false, failure: failure(.linkFailed)))
        check("C25", r, phase: "Connecting", effects: [])
        r.fire(.linkFailedToConnect(sameDevice: false, failure: failure(.linkFailed)))
        check("C25", r, phase: "Connecting", effects: [])
        r = rig(manual, upTo: "Ready")
        r.fire(.adapterChanged(.poweredOff, now: 2000))
        r.fire(.linkConnected(sameDevice: true))
        check("C25", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: [])
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        check("C25", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: [])
        r.fire(.linkFailedToConnect(sameDevice: true, failure: failure(.linkFailed)))
        check("C25", r, phase: "Disconnected(Failed:ADAPTER_UNAVAILABLE)", effects: [])
        r = rig(manual, upTo: "DiscoveringServices")
        r.fire(.discoveryFinished(generation: 9, failure: nil))
        check("C25", r, phase: "DiscoveringServices", effects: [])
        XCTAssertFalse(Core.acceptsDiscoveryCallback(r.state, sameDevice: true, generation: 9), "C25 탐색 콜백 세대")
        XCTAssertTrue(Core.acceptsDiscoveryCallback(r.state, sameDevice: true, generation: 1), "C25 탐색 콜백")
    }

    // MARK: GATT 진입·등록

    func test_gattAdmissionAndRegistration() {
        // C22
        let expectations: [(String, String?)] = [
            ("Ready", nil),
            ("Connecting", "NOT_READY"), ("DiscoveringServices", "NOT_READY"), ("Configuring", "NOT_READY"),
            ("Disconnected", "NOT_CONNECTED"),
        ]
        for (phase, code) in expectations {
            let r = rig(manual, upTo: phase)
            XCTAssertEqual(Core.gattAdmission(r.state)?.value, code, "C22 \(phase)")
        }
        var r = rig(manual, upTo: "Ready")
        r.fire(.disconnect(hasLinkTarget: true, linked: true))
        XCTAssertEqual(Core.gattAdmission(r.state)?.value, "NOT_CONNECTED", "C22 Disconnecting")
        r = rig(auto, upTo: "Ready")
        r.fire(.linkDisconnected(sameDevice: true, failure: failure(.linkFailed)))
        XCTAssertEqual(Core.gattAdmission(r.state)?.value, "NOT_CONNECTED", "C22 Recovering")
        r = rig(manual, upTo: "Ready")
        r.fire(.close)
        XCTAssertEqual(Core.gattAdmission(r.state)?.value, "CLIENT_CLOSED", "C22 닫힘")

        // GATT 콜백 수용: 같은 세대의 Configuring·Ready 만
        for (phase, accepts) in [("Connecting", false), ("DiscoveringServices", false), ("Configuring", true), ("Ready", true)] {
            let s = rig(manual, upTo: phase).state
            XCTAssertEqual(Core.acceptsGattCallback(s, sameDevice: true, generation: 1), accepts, "C22 콜백 \(phase)")
            XCTAssertFalse(Core.acceptsGattCallback(s, sameDevice: true, generation: 2), "C22 콜백 세대 \(phase)")
            XCTAssertFalse(Core.acceptsGattCallback(s, sameDevice: false, generation: 1), "C22 콜백 기기 \(phase)")
        }

        // poison 은 Configuring·Ready 에서만
        for (phase, poisons) in [("Connecting", false), ("DiscoveringServices", false), ("Configuring", true), ("Ready", true), ("Disconnected", false)] {
            r = rig(manual, upTo: phase)
            r.fire(.operationsPoisoned(failure: failure(.operationTimeout)))
            if poisons {
                check("C22", r, phase: "Disconnected(Failed:OPERATION_TIMEOUT)")
                XCTAssertEqual(r.lastEffects.last.map { name($0) }, "cancelPeripheralConnection", "C22 poison 취소 \(phase)")
            } else {
                XCTAssertTrue(r.lastEffects.isEmpty, "C22 poison 무시 \(phase)")
            }
        }

        // C23
        r = rig(manual, upTo: "Disconnected")
        r.fire(.registeredStartFailed(failure: failure(.peripheralNotFound)))
        check("C23", r, phase: "Disconnected(Failed:PERIPHERAL_NOT_FOUND)",
              effects: ["publish(Disconnected(Failed:PERIPHERAL_NOT_FOUND))", "diagnostic(PERIPHERAL_NOT_FOUND)"])
        r = rig(manual, upTo: "Connecting")
        r.fire(.registeredStartFailed(failure: failure(.peripheralNotFound)))
        check("C23", r, phase: "Connecting", effects: [])
        r = rig(manual, upTo: "Disconnected")
        r.fire(.close)
        r.fire(.registeredStartFailed(failure: failure(.peripheralNotFound)))
        check("C23", r, phase: "Disconnected(Initial)", effects: [])
    }
}
