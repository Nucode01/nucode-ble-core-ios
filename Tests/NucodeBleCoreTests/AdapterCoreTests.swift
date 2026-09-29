import XCTest
import NucodeBleCore

/// 어댑터 판정 상태 기계 표 시험(contract/states.md §6, 행 id 는 .plans/refactor-R5-*.md 의 A01~A15).
/// 공개 타입에 `Equatable` 이 없어 할 일과 실패를 표기 문자열로 비교한다.
final class AdapterCoreTests: XCTestCase {
    typealias Core = AdapterCore

    private let offMessage = "Bluetooth 가 꺼져 있다"
    private let timeoutMessage = "어댑터 상태를 2000ms 안에 알 수 없었다"

    private func fresh() -> Core.State { Core.State() }

    // MARK: 표기

    private func name(_ failure: BLEFailure) -> String {
        "\(failure.code.value) \"\(failure.message)\" \(failure.retryability.rawValue)"
    }

    private func name(_ outcome: Core.GateOutcome) -> String {
        switch outcome {
        case .admitted: "ok"
        case .failed(let failure): name(failure)
        case .cancelled: "cancelled"
        case .closed: "closed"
        }
    }

    private func name(_ effect: Core.Effect) -> String {
        switch effect {
        case .publish(let value): "publish(\(value))"
        case .armGateDeadline(let id, let ms): "arm(g\(id),\(ms))"
        case .finishGate(let id, let outcome): "finish(g\(id),\(name(outcome)))"
        case .closeStates: "closeStates"
        }
    }

    private func names(_ effects: [Core.Effect]) -> [String] { effects.map(name) }

    private func fail(_ code: FailureCode, _ message: String, _ retry: Retryability? = nil) -> String {
        name(BLEFailure(code: code, message: message, retryability: retry))
    }

    /// 사건을 차례로 넣고 마지막 상태와 사건별 할 일을 돌려준다
    private func run(_ start: Core.State, _ events: [Core.Event]) -> (Core.State, [[String]]) {
        var state = start
        var all: [[String]] = []
        for event in events {
            let (next, effects) = Core.step(state, event)
            state = next
            all.append(names(effects))
        }
        return (state, all)
    }

    private func at(_ radio: Core.Radio, _ auth: Core.Authorization = .allowedAlways, from start: Core.State? = nil) -> Core.State {
        run(start ?? fresh(), [.platform(radio, auth)]).0
    }

    private func waiting(_ count: Int, on state: Core.State? = nil) -> Core.State {
        run(state ?? fresh(), Array(repeating: .gateRequested, count: count)).0
    }

    // MARK: 값 옮김과 게시

    func testA01_A02_A03_A13_valueMappingAndPublishing() {
        let s0 = fresh()
        XCTAssertEqual(Core.value(s0), .unknown, "A01")
        XCTAssertFalse(Core.isClosed(s0), "A01")
        XCTAssertEqual(Core.nextGateID(s0), 1, "A01")

        let row = "A02"
        let table: [(String, Core.Radio, Core.Authorization, AdapterState)] = [
            ("unknown/notDetermined", .unknown, .notDetermined, .unknown),
            ("unknown/allowedAlways", .unknown, .allowedAlways, .unknown),
            ("resetting", .resetting, .allowedAlways, .resetting),
            ("resetting/notDetermined", .resetting, .notDetermined, .resetting),
            ("unsupported", .unsupported, .allowedAlways, .unsupported),
            ("unauthorized/notDetermined", .unauthorized, .notDetermined, .unauthorized(canRequest: true)),
            ("unauthorized/denied", .unauthorized, .denied, .unauthorized(canRequest: false)),
            ("unauthorized/restricted", .unauthorized, .restricted, .unauthorized(canRequest: false)),
            ("unauthorized/allowedAlways", .unauthorized, .allowedAlways, .unauthorized(canRequest: false)),
            ("poweredOff", .poweredOff, .allowedAlways, .poweredOff),
            ("poweredOn", .poweredOn, .allowedAlways, .ready),
            ("unknown/denied", .unknown, .denied, .unauthorized(canRequest: false)),
            ("poweredOn/denied", .poweredOn, .denied, .unauthorized(canRequest: false)),
        ]
        for (id, radio, auth, expected) in table {
            XCTAssertEqual(Core.map(radio: radio, authorization: auth), expected, "\(row) \(id)")
            let (state, effects) = run(fresh(), [.platform(radio, auth)])
            XCTAssertEqual(Core.value(state), expected, "\(row) \(id)")
            XCTAssertEqual(effects, [expected == .unknown ? [] : ["publish(\(expected))"]], "\(row) \(id)")
        }

        // A03 같은 값은 게시하지 않는다
        let ready = at(.poweredOn)
        XCTAssertEqual(run(ready, [.platform(.poweredOn, .allowedAlways)]).1, [[]], "A03")

        // A13 이탈 값은 게시만 한다
        XCTAssertEqual(run(ready, [.platform(.poweredOff, .allowedAlways)]).1, [["publish(poweredOff)"]], "A13")
        XCTAssertEqual(run(ready, [.platform(.unknown, .allowedAlways)]).1, [["publish(unknown)"]], "A13")
    }

    // MARK: 즉시 판정과 대기

    func testA04_A05_immediateVerdictAndQueueing() {
        let ok = "finish(g1,ok)"
        let row = "A04"
        let table: [(String, Core.State, String)] = [
            ("ready", at(.poweredOn), ok),
            ("poweredOff", at(.poweredOff), "finish(g1,\(fail(.adapterUnavailable, offMessage)))"),
            ("resetting", at(.resetting), "finish(g1,\(fail(.adapterUnavailable, "Bluetooth 가 재설정 중이다")))"),
            ("unsupported", at(.unsupported), "finish(g1,\(fail(.bleUnsupported, "이 기기는 BLE central 을 지원하지 않는다")))"),
            ("unauthorized(true)", at(.unauthorized, .notDetermined),
             "finish(g1,\(fail(.permissionDenied, "Bluetooth 권한이 없다", .afterEnvironmentChange)))"),
            ("unauthorized(false)", at(.unauthorized, .denied),
             "finish(g1,\(fail(.permissionDenied, "Bluetooth 권한이 없다", .never)))"),
        ]
        for (id, start, expected) in table {
            let (state, effects) = run(start, [.gateRequested])
            XCTAssertEqual(effects, [[expected]], "\(row) \(id)")
            XCTAssertTrue(state.waiting.isEmpty, "\(row) \(id)")
            XCTAssertEqual(Core.nextGateID(state), 2, "\(row) \(id)")
        }

        // A05 unknown 이면 기한을 걸고 줄에 선다
        let (one, e1) = run(fresh(), [.gateRequested])
        XCTAssertEqual(e1, [["arm(g1,2000)"]], "A05")
        XCTAssertEqual(one.waiting.map(\.id), [1], "A05")
        let (two, e2) = run(one, [.gateRequested])
        XCTAssertEqual(e2, [["arm(g2,2000)"]], "A05")
        XCTAssertEqual(two.waiting.map(\.id), [1, 2], "A05")
        XCTAssertEqual(Core.nextGateID(two), 3, "A05")
    }

    func testA06_A07_A10_waitingGatesResolveOnPlatformChange() {
        let two = waiting(2)
        let (ready, e6) = run(two, [.platform(.poweredOn, .allowedAlways)])
        XCTAssertEqual(e6, [["publish(ready)", "finish(g1,ok)", "finish(g2,ok)"]], "A06")
        XCTAssertTrue(ready.waiting.isEmpty, "A06")

        let one = waiting(1)
        XCTAssertEqual(run(one, [.platform(.poweredOff, .allowedAlways)]).1,
                       [["publish(poweredOff)", "finish(g1,\(fail(.adapterUnavailable, offMessage)))"]], "A07")

        // A10 기한 전 unknown 은 계속 기다린다
        let (still, e10) = run(one, [.platform(.unknown, .allowedAlways)])
        XCTAssertEqual(e10, [[]], "A10")
        XCTAssertEqual(still.waiting.map(\.id), [1], "A10")
    }

    // MARK: 기한

    func testA08_A09_deadlineAndPermissionPopupException() {
        let one = waiting(1)
        let timeout = "finish(g1,\(fail(.adapterUnavailable, timeoutMessage)))"

        // A08
        for auth in [nil, Core.Authorization.allowedAlways] as [Core.Authorization?] {
            let (state, effects) = run(one, [.gateDeadlineFired(1, authorization: auth)])
            XCTAssertEqual(effects, [[timeout]], "A08 \(String(describing: auth))")
            XCTAssertTrue(state.waiting.isEmpty, "A08")
        }

        // A09 권한 팝업 답을 기다리는 중이면 기한이 지나도 계속 기다린다
        let (popup, e0) = run(one, [.gateDeadlineFired(1, authorization: .notDetermined)])
        XCTAssertEqual(e0, [[]], "A09")
        XCTAssertEqual(popup.waiting.map(\.id), [1], "A09")
        XCTAssertEqual(popup.waiting.map(\.deadlineReached), [true], "A09")
        XCTAssertEqual(run(popup, [.platform(.unknown, .allowedAlways)]).1, [[timeout]], "A09 unknown")
        XCTAssertEqual(run(popup, [.platform(.poweredOn, .allowedAlways)]).1, [["publish(ready)", "finish(g1,ok)"]], "A09 ready")
        XCTAssertEqual(run(popup, [.platform(.unauthorized, .denied)]).1,
                       [["publish(unauthorized(canRequest: false))",
                         "finish(g1,\(fail(.permissionDenied, "Bluetooth 권한이 없다", .never)))"]], "A09 denied")
        XCTAssertEqual(run(popup, [.platform(.unknown, .notDetermined)]).1, [[]], "A09 still popup")
    }

    // MARK: 취소

    func testA11_callerCancellation() {
        let one = waiting(1)
        let (cancelled, e) = run(one, [.gateCancelled(1)])
        XCTAssertEqual(e, [["finish(g1,cancelled)"]], "A11")
        XCTAssertTrue(cancelled.waiting.isEmpty, "A11")

        // 끝난 뒤의 만료·값 변화는 그 대기에 손대지 않는다
        XCTAssertEqual(run(cancelled, [.gateDeadlineFired(1, authorization: nil)]).1, [[]], "A11")
        XCTAssertEqual(run(cancelled, [.platform(.poweredOn, .allowedAlways)]).1, [["publish(ready)"]], "A11")
        // 없는 id·끝난 id
        XCTAssertEqual(run(cancelled, [.gateCancelled(1), .gateCancelled(99)]).1, [[], []], "A11")
        // 하나만 취소하면 나머지는 남는다
        let two = waiting(2)
        let (rest, _) = run(two, [.gateCancelled(1)])
        XCTAssertEqual(rest.waiting.map(\.id), [2], "A11")
    }

    // MARK: 사용 설명 키

    func testA12_missingUsageDescription() {
        let one = waiting(1)
        XCTAssertEqual(run(one, [.usageDescriptionMissing]).1,
                       [["publish(unauthorized(canRequest: false))",
                         "finish(g1,\(fail(.permissionDenied, "Bluetooth 권한이 없다", .never)))"]], "A12")
    }

    // MARK: 닫기와 재확인

    func testA14_close() {
        let two = waiting(2)
        let closedFailure = "closed"
        let (closed, e) = run(two, [.close])
        XCTAssertEqual(e, [["finish(g1,\(closedFailure))", "finish(g2,\(closedFailure))", "closeStates"]], "A14")
        XCTAssertTrue(closed.waiting.isEmpty, "A14")
        XCTAssertTrue(Core.isClosed(closed), "A14")

        let (_, after) = run(closed, [
            .gateRequested, .platform(.poweredOn, .allowedAlways), .usageDescriptionMissing,
            .gateDeadlineFired(1, authorization: nil), .close,
        ])
        XCTAssertEqual(after, [["finish(g3,closed)"], [], [], [], []], "A14")

        // 닫혀도 마지막 값은 남는다
        let readyClosed = run(at(.poweredOn), [.close]).0
        XCTAssertEqual(Core.value(readyClosed), .ready, "A14")
    }

    func testA15_recheck() {
        XCTAssertNil(Core.recheck(.ready), "A15")
        let others: [AdapterState] = [.unknown, .unsupported, .unauthorized(canRequest: true), .unauthorized(canRequest: false), .poweredOff, .resetting]
        for value in others {
            guard let failure = Core.recheck(value) else { return XCTFail("A15 \(value)") }
            XCTAssertEqual(name(failure), fail(.adapterUnavailable, "판정 뒤 어댑터가 Ready 를 벗어났다"), "A15 \(value)")
        }
        XCTAssertEqual(Core.unknownWaitLimit, 2000, "A15")
    }
}
