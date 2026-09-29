import XCTest
import NucodeBleCore

/// GATT 작업 큐 상태 기계 표 시험(contract/states.md §8·§10, 행 id 는 .plans/refactor-R4-*.md 의 Q01~Q18).
/// 공개 타입에 `Equatable` 이 없어 할 일과 실패를 표기 문자열로 비교한다.
final class GattQueueCoreTests: XCTestCase {
    typealias Core = GattQueueCore

    private let timeout = 5000
    private let a = CharacteristicRef(service: ServiceRef(uuid: BLEUUID(string: "1800")!, instanceIndex: 0), uuid: BLEUUID(string: "2a00")!, instanceIndex: 0)
    private let b = CharacteristicRef(service: ServiceRef(uuid: BLEUUID(string: "1800")!, instanceIndex: 0), uuid: BLEUUID(string: "2a01")!, instanceIndex: 0)
    private let c = CharacteristicRef(service: ServiceRef(uuid: BLEUUID(string: "1800")!, instanceIndex: 0), uuid: BLEUUID(string: "2a02")!, instanceIndex: 0)

    private let timeoutMessage = "read 이 5000ms 안에 끝나지 않았다"
    private let invalidatedMessage = "앞선 작업의 기한 초과로 세대가 폐기됐다"

    private func fresh() -> Core.State { Core.State(timeoutMilliseconds: timeout) }

    // MARK: 표기

    private func name(_ failure: BLEFailure) -> String { "\(failure.code.value)" }

    private func name(_ outcome: Core.Outcome) -> String {
        switch outcome {
        case .success(let data): data.isEmpty ? "ok" : "ok(\(data.map { String($0) }.joined(separator: ",")))"
        case .failure(let failure): failure.code.value
        }
    }

    private func name(_ effect: Core.Effect) -> String {
        switch effect {
        case .armDeadline(let token, let ms): "arm(t\(token),\(ms))"
        case .cancelDeadline: "cancelDeadline"
        case .start(let id): "start(#\(id))"
        case .complete(let id, let outcome): "complete(#\(id),\(name(outcome)))"
        case .advance: "advance"
        case .judgeLater(let id): "judgeLater(#\(id))"
        case .deliverWriteAck(let id): "ackWrite(#\(id))"
        case .wakeWriteJob(let id): "wakeWrite(#\(id))"
        case .poison(let failure): "poison(\(failure.code.value))"
        case .unmatched: "unmatched"
        }
    }

    /// 사건의 모든 case 를 `default` 없이 이름 붙인다. 취소류 case 가 생기면 컴파일이 이 시험을 다시 보게 한다
    private func name(_ event: Core.Event) -> String {
        switch event {
        case .submit(let kind, _): "submit(\(kind.label))"
        case .readResponded: "readResponded"
        case .notifyStateResponded(_, let isNotifying, _): "notifyStateResponded(\(isNotifying))"
        case .writeResponded: "writeResponded"
        case .readyToSendWithoutResponse: "readyToSendWithoutResponse"
        case .jobProgressed(let id): "jobProgressed(#\(id))"
        case .jobFinished(let id, let outcome): "jobFinished(#\(id),\(name(outcome)))"
        case .advance: "advance"
        case .deadlineFired(let token): "deadlineFired(t\(token))"
        case .deadlineJudged(let id): "deadlineJudged(#\(id))"
        case .invalidate: "invalidate"
        }
    }

    private func names(_ effects: [Core.Effect]) -> [String] { effects.map(name) }

    // MARK: 도우미

    /// 사건을 넣고 할 일이 기대와 같은지 본다. 새 상태를 돌려준다
    @discardableResult
    private func check(
        _ row: String, _ state: Core.State, _ event: Core.Event, _ expected: [String],
        file: StaticString = #filePath, line: UInt = #line
    ) -> Core.State {
        let (next, effects) = Core.step(state, event)
        XCTAssertEqual(names(effects), expected, "\(row): \(name(event))", file: file, line: line)
        return next
    }

    /// 할 일을 보지 않고 사건 열로 상태를 만든다
    private func given(_ events: [Core.Event], from state: Core.State? = nil) -> Core.State {
        events.reduce(state ?? fresh()) { Core.step($0, $1).0 }
    }

    private func expectState(
        _ row: String, _ state: Core.State, current: Core.OperationID?, waiting: [Core.OperationID],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(Core.current(state)?.id, current, "\(row): current", file: file, line: line)
        XCTAssertEqual(state.waiting.map(\.id), waiting, "\(row): waiting", file: file, line: line)
        XCTAssertEqual(Core.isIdle(state), current == nil && waiting.isEmpty, "\(row): isIdle", file: file, line: line)
    }

    private func read(_ ref: CharacteristicRef) -> Core.Event { .submit(kind: .read, characteristic: ref) }
    private func value(_ ref: CharacteristicRef, _ bytes: [UInt8] = []) -> Core.Event {
        .readResponded(ref, value: Data(bytes), failure: nil)
    }

    private func failure(_ code: FailureCode = .gattStatusFailed, _ message: String = "실패") -> BLEFailure {
        BLEFailure(code: code, message: message)
    }

    // MARK: 접수·차례

    func test_submitAndTurn() {
        // Q01
        let start = fresh()
        check("Q01", start, .advance, [])
        expectState("Q01", start, current: nil, waiting: [])

        // Q02: 기한이 start 보다 먼저
        var state = check("Q02", fresh(), read(a), ["arm(t1,5000)", "start(#1)"])
        expectState("Q02", state, current: 1, waiting: [])

        // Q03: 줄 끝에 들어가고, 완료 뒤 advance 로 다음이 시작된다
        state = check("Q03", state, read(b), [])
        expectState("Q03", state, current: 1, waiting: [2])
        state = check("Q03", state, value(a), ["cancelDeadline", "complete(#1,ok)", "advance"])
        expectState("Q03", state, current: nil, waiting: [2])
        state = check("Q03", state, .advance, ["arm(t2,5000)", "start(#2)"])
        // 세 개면 FIFO
        state = given([read(c)], from: state)
        expectState("Q03", state, current: 2, waiting: [3])
        state = check("Q03", state, value(b), ["cancelDeadline", "complete(#2,ok)", "advance"])
        check("Q03", state, .advance, ["arm(t3,5000)", "start(#3)"])
    }

    func test_advanceAndReentrancy() {
        // Q13
        let waitingOnly = given([read(a), read(b), value(a)])
        expectState("Q13", waitingOnly, current: nil, waiting: [2])
        check("Q13", waitingOnly, .advance, ["arm(t2,5000)", "start(#2)"])
        let busy = given([read(a), read(b)])
        check("Q13", busy, .advance, [])
        check("Q13", fresh(), .advance, [])

        // Q14: 완료 step 뒤 advance 전에 접수된 것은 줄 끝, 시작은 FIFO
        var state = check("Q14", given([read(a), read(b)]), value(a), ["cancelDeadline", "complete(#1,ok)", "advance"])
        state = check("Q14", state, read(c), ["arm(t2,5000)", "start(#2)"])
        expectState("Q14", state, current: 2, waiting: [3])
        check("Q14", state, .advance, [])

        // Q16
        let idle = fresh()
        XCTAssertTrue(Core.isIdle(idle), "Q16")
        XCTAssertNil(Core.current(idle), "Q16")
        let one = given([.submit(kind: .setNotify(enabled: true), characteristic: b), read(a)])
        XCTAssertFalse(Core.isIdle(one), "Q16")
        let op = Core.current(one)
        XCTAssertEqual(op?.id, 1, "Q16")
        XCTAssertEqual(op?.kind, .setNotify(enabled: true), "Q16")
        XCTAssertEqual(op?.characteristic, b, "Q16")
        XCTAssertFalse(Core.isIdle(given([read(a), read(b), value(a)])), "Q16 대기만 있어도 idle 아님")
    }

    // MARK: 콜백 짝짓기

    func test_callbackMatching() {
        // Q04
        let reading = given([read(a)])
        check("Q04", reading, value(a, [7]), ["cancelDeadline", "complete(#1,ok(7))", "advance"])
        check("Q04", reading, .readResponded(a, value: nil, failure: failure()), ["cancelDeadline", "complete(#1,GATT_STATUS_FAILED)", "advance"])
        let other = check("Q04", reading, value(b), ["unmatched"])
        expectState("Q04", other, current: 1, waiting: [])
        check("Q04", given([.submit(kind: .write, characteristic: a)]), value(a), ["unmatched"])
        check("Q04", fresh(), value(a), ["unmatched"])

        // Q05
        let subscribing = given([.submit(kind: .setNotify(enabled: true), characteristic: a)])
        check("Q05", subscribing, .notifyStateResponded(a, isNotifying: true, failure: nil), ["cancelDeadline", "complete(#1,ok)", "advance"])
        let (_, mismatch) = Core.step(subscribing, .notifyStateResponded(a, isNotifying: false, failure: nil))
        if case .complete(_, .failure(let f)) = mismatch[1] {
            XCTAssertEqual(f.code.value, "GATT_OPERATION_CALLBACK_MISMATCH", "Q05")
            XCTAssertEqual(f.message, "subscribe 응답의 알림 상태(false)가 요청과 다르다", "Q05")
        } else {
            XCTFail("Q05: 불일치는 실패로 끝나야 한다: \(names(mismatch))")
        }
        XCTAssertEqual(names(mismatch), ["cancelDeadline", "complete(#1,GATT_OPERATION_CALLBACK_MISMATCH)", "advance"], "Q05")
        check("Q05", subscribing, .notifyStateResponded(a, isNotifying: true, failure: failure()), ["cancelDeadline", "complete(#1,GATT_STATUS_FAILED)", "advance"])
        check("Q05", subscribing, .notifyStateResponded(b, isNotifying: true, failure: nil), ["unmatched"])
        check("Q05", readingState(), .notifyStateResponded(a, isNotifying: true, failure: nil), ["unmatched"])
        check("Q05", fresh(), .notifyStateResponded(a, isNotifying: true, failure: nil), ["unmatched"])
        let unsubscribing = given([.submit(kind: .setNotify(enabled: false), characteristic: a)])
        let (_, unsubMismatch) = Core.step(unsubscribing, .notifyStateResponded(a, isNotifying: true, failure: nil))
        if case .complete(_, .failure(let f)) = unsubMismatch[1] {
            XCTAssertEqual(f.message, "unsubscribe 응답의 알림 상태(true)가 요청과 다르다", "Q05")
        } else {
            XCTFail("Q05: unsubscribe 불일치: \(names(unsubMismatch))")
        }

        // Q15: 같은 참조의 두 read 는 순서대로 끝난다
        var state = given([read(a), read(a)])
        state = check("Q15", state, value(a), ["cancelDeadline", "complete(#1,ok)", "advance"])
        state = check("Q15", state, .advance, ["arm(t2,5000)", "start(#2)"])
        check("Q15", state, value(a), ["cancelDeadline", "complete(#2,ok)", "advance"])
    }

    private func readingState() -> Core.State { given([read(a)]) }

    // MARK: write 조각

    func test_writeChunks() {
        let writing = given([.submit(kind: .write, characteristic: a)])

        // Q06: 조각 확인은 job 에 넘기고 완료는 job 이 정한다
        let after = check("Q06", writing, .writeResponded(a), ["ackWrite(#1)"])
        expectState("Q06", after, current: 1, waiting: [])
        check("Q06", writing, .writeResponded(b), ["unmatched"])
        check("Q06", readingState(), .writeResponded(a), ["unmatched"])
        check("Q06", fresh(), .writeResponded(a), ["unmatched"])
        check("Q06", writing, .readyToSendWithoutResponse, ["wakeWrite(#1)"])
        check("Q06", readingState(), .readyToSendWithoutResponse, [])
        check("Q06", fresh(), .readyToSendWithoutResponse, [])

        // Q07: 조각마다 기한을 다시 건다
        let progressed = check("Q07", writing, .jobProgressed(1), ["arm(t2,5000)"])
        check("Q07", progressed, .jobProgressed(1), ["arm(t3,5000)"])
        check("Q07", writing, .jobProgressed(2), [])
        check("Q07", fresh(), .jobProgressed(1), [])

        // Q18: job 끝
        check("Q18", writing, .jobFinished(1, .failure(failure())), ["cancelDeadline", "complete(#1,GATT_STATUS_FAILED)", "advance"])
        check("Q18", writing, .jobFinished(1, .success(Data())), ["cancelDeadline", "complete(#1,ok)", "advance"])
        check("Q18", writing, .jobFinished(2, .success(Data())), [])
        check("Q18", fresh(), .jobFinished(1, .success(Data())), [])
    }

    // MARK: 기한·우편함

    func test_deadlineMailbox() {
        // Q08: 만료는 판정하지 않는다
        let running = given([read(a)])
        let fired = check("Q08", running, .deadlineFired(token: 1), ["judgeLater(#1)"])
        expectState("Q08", fired, current: 1, waiting: [])
        check("Q08", running, .deadlineFired(token: 9), [])
        check("Q08", fresh(), .deadlineFired(token: 1), [])
        let finished = given([read(a), value(a)])
        check("Q08", finished, .deadlineFired(token: 1), [])
        let rearmed = given([.submit(kind: .write, characteristic: a), .jobProgressed(1)])
        check("Q08", rearmed, .deadlineFired(token: 1), [])
        check("Q08", rearmed, .deadlineFired(token: 2), ["judgeLater(#1)"])

        // Q09: 이미 도착한 완료가 기한을 이긴다
        var state = check("Q09", running, .deadlineFired(token: 1), ["judgeLater(#1)"])
        state = check("Q09", state, value(a), ["cancelDeadline", "complete(#1,ok)", "advance"])
        check("Q09", state, .deadlineJudged(1), [])

        // Q10: 판정 때 아직 진행 중이면 timeout + 나머지 폐기 + poison
        state = given([read(a), read(b), read(c)])
        state = check("Q10", state, .deadlineFired(token: 1), ["judgeLater(#1)"])
        let (judged, effects) = Core.step(state, .deadlineJudged(1))
        XCTAssertEqual(names(effects), [
            "complete(#1,OPERATION_TIMEOUT)", "complete(#2,OPERATION_INVALIDATED)", "complete(#3,OPERATION_INVALIDATED)", "poison(OPERATION_TIMEOUT)",
        ], "Q10")
        expectState("Q10", judged, current: nil, waiting: [])
        guard case .complete(_, .failure(let timeoutFailure)) = effects[0],
              case .complete(_, .failure(let dropped)) = effects[1],
              case .complete(_, .failure(let droppedLast)) = effects[2],
              case .poison(let poisoned) = effects[3] else { return XCTFail("Q10: 할 일 모양") }
        XCTAssertEqual(timeoutFailure.message, timeoutMessage, "Q10")
        XCTAssertEqual(dropped.message, invalidatedMessage, "Q10")
        XCTAssertEqual(droppedLast.message, invalidatedMessage, "Q10")
        XCTAssertEqual(poisoned.message, timeoutMessage, "Q10")
        // 판정 뒤에는 다음을 시작하지 않는다
        check("Q10", judged, .advance, [])

        // Q17: 판정 뒤 늦은 사건
        check("Q17", judged, value(a), ["unmatched"])
        check("Q17", judged, .jobFinished(1, .success(Data())), [])
        check("Q17", judged, .jobProgressed(1), [])
        check("Q17", judged, .deadlineJudged(1), [])
    }

    // MARK: 무효화

    func test_invalidate() {
        // Q12
        let queue = given([read(a), read(b), read(c)])
        let f = failure(.clientClosed, "닫혔다")
        let (cleared, effects) = Core.step(queue, .invalidate(f))
        XCTAssertEqual(names(effects), [
            "cancelDeadline", "complete(#1,CLIENT_CLOSED)", "complete(#2,CLIENT_CLOSED)", "complete(#3,CLIENT_CLOSED)",
        ], "Q12")
        expectState("Q12", cleared, current: nil, waiting: [])
        check("Q12", fresh(), .invalidate(f), [])
        // 다시 쓸 수 있다: 바로 start, 번호는 이어진다
        check("Q12", cleared, read(a), ["arm(t2,5000)", "start(#4)"])
    }

    // MARK: 떼어 내기

    func test_callerDetach() {
        // Q11: 호출자 사건 없이 끝까지 간다. 사건은 완료·기한 판정·무효화·차례뿐이다
        let events: [Core.Event] = [read(a), read(b), value(a), .advance, value(b)]
        XCTAssertEqual(events.map(name), [
            "submit(read)", "submit(read)", "readResponded", "advance", "readResponded",
        ], "Q11")
        var state = fresh()
        var all: [String] = []
        for event in events {
            let (next, effects) = Core.step(state, event)
            state = next
            all += names(effects)
        }
        XCTAssertEqual(all.filter { $0.hasPrefix("complete") }, ["complete(#1,ok)", "complete(#2,ok)"], "Q11")
        expectState("Q11", state, current: nil, waiting: [])

        // 이름 붙이는 도우미가 모든 사건을 덮는다
        let sample: [Core.Event] = [
            read(a), value(a), .notifyStateResponded(a, isNotifying: true, failure: nil), .writeResponded(a), .readyToSendWithoutResponse,
            .jobProgressed(1), .jobFinished(1, .success(Data())), .advance, .deadlineFired(token: 1), .deadlineJudged(1), .invalidate(failure()),
        ]
        XCTAssertEqual(Set(sample.map(name)).count, 11, "Q11")
    }
}
