import Foundation

/// GATT 작업 큐의 상태 기계(contract/states.md §8·§10). `(상태, 사건) → (새 상태, 할 일 목록)` 순수 함수다.
/// 입출력·시간·스레드·플랫폼 타입을 쓰지 않는다. 기한은 `armDeadline`/`deadlineFired` 로 오간다.
///
/// 우편함 규칙(기한 만료와 이미 도착한 콜백의 순서):
/// 1. `deadlineFired` 는 판정하지 않는다. 마지막으로 건 기한이고 작업이 진행 중이면 `judgeLater` 만 낸다.
/// 2. 실행 쪽은 `judgeLater` 를 우편함 끝에 `deadlineJudged` 로 넣는다.
/// 3. 그 사이 먼저 들어와 있던 완료 콜백은 판정보다 먼저 step 되어 작업을 끝낸다. 판정 때 진행 중이 아니면 무시한다.
/// 4. 판정 때 같은 작업이 아직 진행 중이면 그것은 `OPERATION_TIMEOUT`, 기다리던 것은 `OPERATION_INVALIDATED`, 마지막에 `poison`.
package enum GattQueueCore {
    package typealias OperationID = UInt64

    package enum Kind: Equatable {
        case read
        case setNotify(enabled: Bool)
        case write

        package var label: String {
            switch self {
            case .read: "read"
            case .setNotify(let enabled): enabled ? "subscribe" : "unsubscribe"
            case .write: "write"
            }
        }
    }

    /// 접수된 작업 하나. 플랫폼 콜백은 참조로만 짝을 짓는다(iOS 콜백에는 작업 ID 가 없다)
    package struct Operation {
        package let id: OperationID
        package let kind: Kind
        package let characteristic: CharacteristicRef
    }

    package struct State {
        /// 기다리는 줄(먼저 들어온 것이 앞)
        package fileprivate(set) var waiting: [Operation] = []
        /// 플랫폼에 나가 있는 작업. 한 번에 하나
        package fileprivate(set) var inFlight: Operation?
        package fileprivate(set) var nextOperationID: OperationID = 0
        /// 마지막으로 건 기한의 번호
        package fileprivate(set) var deadlineToken: UInt64 = 0
        package let timeoutMilliseconds: Int

        package init(timeoutMilliseconds: Int) {
            self.timeoutMilliseconds = timeoutMilliseconds
        }
    }

    package enum Outcome {
        case success(Data)
        case failure(BLEFailure)
    }

    package enum Event {
        case submit(kind: Kind, characteristic: CharacteristicRef)
        case readResponded(CharacteristicRef, value: Data?, failure: BLEFailure?)
        case notifyStateResponded(CharacteristicRef, isNotifying: Bool, failure: BLEFailure?)
        case writeResponded(CharacteristicRef)
        case readyToSendWithoutResponse
        case jobProgressed(OperationID)
        case jobFinished(OperationID, Outcome)
        case advance
        case deadlineFired(token: UInt64)
        case deadlineJudged(OperationID)
        case invalidate(BLEFailure)
    }

    package enum Effect {
        case armDeadline(token: UInt64, milliseconds: Int)
        case cancelDeadline
        case start(OperationID)
        case complete(OperationID, Outcome)
        /// 완료 뒤 다음 작업을 시작하라는 뜻. 실행 쪽이 `advance` 사건을 넣는다
        case advance
        case judgeLater(OperationID)
        /// write 조각 하나의 확인을 작업에 넘긴다
        case deliverWriteAck(OperationID)
        case wakeWriteJob(OperationID)
        case poison(BLEFailure)
        /// 진행 중인 작업과 짝이 없는 콜백
        case unmatched
    }

    // MARK: 질의

    package static func isIdle(_ state: State) -> Bool {
        state.inFlight == nil && state.waiting.isEmpty
    }

    package static func current(_ state: State) -> Operation? {
        state.inFlight
    }

    // MARK: 전이

    package static func step(_ state: State, _ event: Event) -> (State, [Effect]) {
        var next = state
        var effects: [Effect] = []
        switch event {
        case .submit(let kind, let characteristic):
            next.nextOperationID += 1
            next.waiting.append(Operation(id: next.nextOperationID, kind: kind, characteristic: characteristic))
            startNextIfIdle(&next, &effects)
        case .readResponded(let characteristic, let value, let failure):
            guard let op = next.inFlight, op.kind == .read, op.characteristic == characteristic else {
                return (state, [.unmatched])
            }
            if let failure {
                finish(&next, &effects, op, .failure(failure))
            } else {
                finish(&next, &effects, op, .success(value ?? Data()))
            }
        case .notifyStateResponded(let characteristic, let isNotifying, let failure):
            guard let op = next.inFlight, case .setNotify(let enabled) = op.kind, op.characteristic == characteristic else {
                return (state, [.unmatched])
            }
            if let failure {
                finish(&next, &effects, op, .failure(failure))
            } else if isNotifying != enabled {
                finish(&next, &effects, op, .failure(BLEFailure(
                    code: .gattOperationCallbackMismatch,
                    message: "\(op.kind.label) 응답의 알림 상태(\(isNotifying))가 요청과 다르다"
                )))
            } else {
                finish(&next, &effects, op, .success(Data()))
            }
        case .writeResponded(let characteristic):
            guard let op = next.inFlight, op.kind == .write, op.characteristic == characteristic else {
                return (state, [.unmatched])
            }
            effects.append(.deliverWriteAck(op.id))
        case .readyToSendWithoutResponse:
            if let op = next.inFlight, op.kind == .write {
                effects.append(.wakeWriteJob(op.id))
            }
        case .jobProgressed(let id):
            // 기한은 조각 하나의 확인 대기 상한이다: 조각마다 다시 건다
            guard next.inFlight?.id == id else { break }
            armDeadline(&next, &effects)
        case .jobFinished(let id, let outcome):
            guard let op = next.inFlight, op.id == id else { break }
            finish(&next, &effects, op, outcome)
        case .advance:
            startNextIfIdle(&next, &effects)
        case .deadlineFired(let token):
            guard token == next.deadlineToken, let op = next.inFlight else { break }
            effects.append(.judgeLater(op.id))
        case .deadlineJudged(let id):
            guard let op = next.inFlight, op.id == id else { break }
            let failure = BLEFailure(
                code: .operationTimeout,
                message: "\(op.kind.label) 이 \(next.timeoutMilliseconds)ms 안에 끝나지 않았다"
            )
            let rest = next.waiting
            next.inFlight = nil
            next.waiting = []
            effects.append(.complete(op.id, .failure(failure)))
            let dropped = BLEFailure(code: .operationInvalidated, message: "앞선 작업의 기한 초과로 세대가 폐기됐다")
            for other in rest { effects.append(.complete(other.id, .failure(dropped))) }
            effects.append(.poison(failure))
        case .invalidate(let failure):
            guard !isIdle(next) else { break }
            let all = (next.inFlight.map { [$0] } ?? []) + next.waiting
            next.inFlight = nil
            next.waiting = []
            effects.append(.cancelDeadline)
            for op in all { effects.append(.complete(op.id, .failure(failure))) }
        }
        return (next, effects)
    }

    private static func startNextIfIdle(_ state: inout State, _ effects: inout [Effect]) {
        guard state.inFlight == nil, !state.waiting.isEmpty else { return }
        let op = state.waiting.removeFirst()
        state.inFlight = op
        armDeadline(&state, &effects)
        effects.append(.start(op.id))
    }

    private static func armDeadline(_ state: inout State, _ effects: inout [Effect]) {
        state.deadlineToken += 1
        effects.append(.armDeadline(token: state.deadlineToken, milliseconds: state.timeoutMilliseconds))
    }

    private static func finish(_ state: inout State, _ effects: inout [Effect], _ op: Operation, _ outcome: Outcome) {
        state.inFlight = nil
        effects += [.cancelDeadline, .complete(op.id, outcome), .advance]
    }
}
