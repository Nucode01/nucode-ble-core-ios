import Foundation

/// 세션 하나의 GATT 작업 큐의 Runtime. 차례 판단은 `GattQueueCore.step` 이 하고 이 클래스는 할 일을 실행한다(docs/v1/ios-design.md §7).
/// 작업의 Waiter 는 이 큐가 소유한다. 호출자가 취소돼도 작업은 큐 순서대로 끝까지 간다(contract/states.md §10).
/// 콜백은 참조로만 짝을 짓는다(iOS 콜백에는 작업 ID 가 없다).
@BLECoreActor
package final class OperationQueue {
    package typealias Kind = GattQueueCore.Kind

    @BLECoreActor
    private final class Entry {
        let start: @BLECoreActor () -> Void
        let completion: (@BLECoreActor (Result<Data, BLEError>) -> Void)?
        let waiter = Waiter<Data>()
        let job: WriteJob?

        init(
            start: @escaping @BLECoreActor () -> Void,
            completion: (@BLECoreActor (Result<Data, BLEError>) -> Void)?,
            job: WriteJob?
        ) {
            self.job = job
            self.start = start
            self.completion = completion
        }
    }

    private let clock: any BLEClock
    /// 차례 상태의 유일한 주인. 쓰기는 `dispatch` 안에서만 한다
    private var core: GattQueueCore.State
    /// 작업 id 별 실행 쪽 손잡이(순서 없음). 차례는 `core` 가 정한다
    private var entries: [GattQueueCore.OperationID: Entry] = [:]
    private var deadline: Task<Void, Never>?
    /// 기한이 지나 세대를 폐기해야 할 때. 큐는 이미 비워졌다
    package var onPoison: (@BLECoreActor (BLEFailure) -> Void)?

    package init(clock: any BLEClock, timeoutMilliseconds: Int) {
        self.clock = clock
        self.core = GattQueueCore.State(timeoutMilliseconds: timeoutMilliseconds)
    }

    package var isIdle: Bool { GattQueueCore.isIdle(core) }

    /// 접수한다. 앞에 아무것도 없으면 바로 시작한다. `completion` 은 결과가 정해질 때 한 번, Waiter 를 깨우기 전에 불린다
    package func submit(
        _ kind: Kind,
        characteristic: CharacteristicRef,
        start: @escaping @BLECoreActor () -> Void,
        completion: (@BLECoreActor (Result<Data, BLEError>) -> Void)? = nil,
        job: WriteJob? = nil
    ) -> Waiter<Data> {
        let entry = Entry(start: start, completion: completion, job: job)
        // Core 가 이 접수에 붙일 id. 바로 시작하면 step 이 낸 start 를 실행하기 전에 사전에 있어야 한다
        let id = core.nextOperationID + 1
        entries[id] = entry
        job?.finish = { [weak self] result in
            self?.dispatch(.jobFinished(id, Self.outcome(of: result)))
        }
        job?.progress = { [weak self] in
            self?.dispatch(.jobProgressed(id))
        }
        dispatch(.submit(kind: kind, characteristic: characteristic))
        return entry.waiter
    }

    // MARK: 콜백

    /// 진행 중인 read 의 응답이면 그 작업을 끝내고 true. 알림이나 다른 참조면 false
    @discardableResult
    package func didUpdateValue(for characteristic: CharacteristicRef, value: Data?, error: PortError?) -> Bool {
        let failure = error.map { GattFailure.status($0, operation: "read") }
        return dispatch(.readResponded(characteristic, value: value, failure: failure))
    }

    /// 진행 중인 subscribe/unsubscribe 의 CCCD 응답이면 끝내고 true. 짝이 없으면 false
    @discardableResult
    package func didUpdateNotificationState(for characteristic: CharacteristicRef, isNotifying: Bool, error: PortError?) -> Bool {
        let label = GattQueueCore.current(core)?.kind.label ?? Kind.setNotify(enabled: isNotifying).label
        let failure = error.map { GattFailure.status($0, operation: label) }
        return dispatch(.notifyStateResponded(characteristic, isNotifying: isNotifying, failure: failure))
    }

    /// 진행 중인 write 의 조각 하나가 확인됐으면 작업에 넘기고 true
    @discardableResult
    package func didWriteValue(for characteristic: CharacteristicRef, error: PortError?) -> Bool {
        dispatch(.writeResponded(characteristic), writeError: error)
    }

    /// 응답 없는 write 가 멈춰 있으면 다시 보내게 한다
    package func readyToSendWriteWithoutResponse() {
        dispatch(.readyToSendWithoutResponse)
    }

    // MARK: 폐기

    /// 진행 중인 것과 기다리는 것을 모두 같은 실패로 끝낸다. 연결이 끝날 때와 닫힐 때 쓴다. 큐는 다시 쓸 수 있다
    package func invalidate(_ failure: BLEFailure) {
        dispatch(.invalidate(failure))
    }

    // MARK: 실행

    /// 사건을 Core 에 넘기고 할 일을 순서대로 실행한다. 상태를 먼저 저장하므로 실행 중 들어온 사건은 새 상태 위에서 step 한다.
    /// 짝 없는 콜백이면 false
    @discardableResult
    private func dispatch(_ event: GattQueueCore.Event, writeError: PortError? = nil) -> Bool {
        let (next, effects) = GattQueueCore.step(core, event)
        core = next
        var matched = true
        for effect in effects {
            switch effect {
            case .armDeadline(let token, let milliseconds):
                armDeadline(token: token, milliseconds: milliseconds)
            case .cancelDeadline:
                deadline?.cancel()
                deadline = nil
            case .start(let id):
                entries[id]?.start()
            case .complete(let id, let outcome):
                complete(id, outcome)
            case .advance:
                dispatch(.advance)
            case .judgeLater(let id):
                // 판정은 우편함 끝에 넣는다. 이미 도착해 있던 완료 콜백이 먼저 처리된다
                Task { @BLECoreActor [weak self] in
                    self?.dispatch(.deadlineJudged(id))
                }
            case .deliverWriteAck(let id):
                entries[id]?.job?.didWrite(error: writeError)
            case .wakeWriteJob(let id):
                entries[id]?.job?.readyToSendWithoutResponse()
            case .poison(let failure):
                onPoison?(failure)
            case .unmatched:
                matched = false
            }
        }
        return matched
    }

    private func armDeadline(token: UInt64, milliseconds: Int) {
        deadline?.cancel()
        deadline = Task { @BLECoreActor [weak self, clock] in
            do { try await clock.sleep(milliseconds: milliseconds) } catch { return }
            self?.dispatch(.deadlineFired(token: token))
        }
    }

    private func complete(_ id: GattQueueCore.OperationID, _ outcome: GattQueueCore.Outcome) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        let result: Result<Data, BLEError>
        switch outcome {
        case .success(let value): result = .success(value)
        case .failure(let failure): result = .failure(BLEError(failure: failure))
        }
        entry.job?.cancel()
        entry.completion?(result)
        entry.waiter.resolve(result.mapError { $0 as any Error })
    }

    private static func outcome(of result: Result<Data, BLEError>) -> GattQueueCore.Outcome {
        switch result {
        case .success(let value): .success(value)
        case .failure(let error): .failure(error.failure)
        }
    }
}
