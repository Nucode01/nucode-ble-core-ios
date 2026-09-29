import Foundation

/// 세션 하나의 GATT 작업 큐. 한 번에 하나만 플랫폼에 나가고, 작업의 Waiter 는 이 큐가 소유한다(docs/v1/ios-design.md §7).
/// 호출자가 취소돼도 작업은 큐 순서대로 끝까지 간다(contract/states.md §10). 콜백은 참조로만 짝을 짓는다(iOS 콜백에는 작업 ID 가 없다).
@BLECoreActor
package final class OperationQueue {
    package enum Kind: Equatable {
        case read
        case setNotify(enabled: Bool)
        case write

        var label: String {
            switch self {
            case .read: "read"
            case .setNotify(let enabled): enabled ? "subscribe" : "unsubscribe"
            case .write: "write"
            }
        }
    }

    @BLECoreActor
    private final class Entry {
        let kind: Kind
        /// 포트 참조(플랫폼에 넘기는 쪽)
        let characteristic: CharacteristicRef
        let start: @BLECoreActor () -> Void
        let completion: (@BLECoreActor (Result<Data, BLEError>) -> Void)?
        let waiter = Waiter<Data>()
        let job: WriteJob?

        init(
            kind: Kind,
            characteristic: CharacteristicRef,
            start: @escaping @BLECoreActor () -> Void,
            completion: (@BLECoreActor (Result<Data, BLEError>) -> Void)?,
            job: WriteJob? = nil
        ) {
            self.job = job
            self.kind = kind
            self.characteristic = characteristic
            self.start = start
            self.completion = completion
        }
    }

    private let clock: any BLEClock
    private let timeoutMilliseconds: Int
    /// 기한이 지나 세대를 폐기해야 할 때. 큐는 이미 비워졌다
    package var onPoison: (@BLECoreActor (BLEFailure) -> Void)?
    private var waiting: [Entry] = []
    private var current: Entry?
    private var deadline: Task<Void, Never>?

    package init(clock: any BLEClock, timeoutMilliseconds: Int) {
        self.clock = clock
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    package var isIdle: Bool { current == nil && waiting.isEmpty }

    /// 접수한다. 앞에 아무것도 없으면 바로 시작한다. `completion` 은 결과가 정해질 때 한 번, Waiter 를 깨우기 전에 불린다
    package func submit(
        _ kind: Kind,
        characteristic: CharacteristicRef,
        start: @escaping @BLECoreActor () -> Void,
        completion: (@BLECoreActor (Result<Data, BLEError>) -> Void)? = nil,
        job: WriteJob? = nil
    ) -> Waiter<Data> {
        let entry = Entry(kind: kind, characteristic: characteristic, start: start, completion: completion, job: job)
        job?.finish = { [weak self, weak entry] result in
            guard let self, let entry else { return }
            self.finish(entry, result)
        }
        job?.progress = { [weak self, weak entry] in
            guard let self, let entry, self.current === entry else { return }
            self.armDeadline(entry)
        }
        waiting.append(entry)
        startNextIfIdle()
        return entry.waiter
    }

    // MARK: 콜백

    /// 진행 중인 read 의 응답이면 그 작업을 끝내고 true. 알림이나 다른 참조면 false
    @discardableResult
    package func didUpdateValue(for characteristic: CharacteristicRef, value: Data?, error: PortError?) -> Bool {
        guard let entry = current, entry.kind == .read, entry.characteristic == characteristic else { return false }
        if let error {
            finish(entry, .failure(BLEError(failure: GattFailure.status(error, operation: "read"))))
        } else {
            finish(entry, .success(value ?? Data()))
        }
        return true
    }

    /// 진행 중인 subscribe/unsubscribe 의 CCCD 응답이면 끝내고 true. 짝이 없으면 false
    @discardableResult
    package func didUpdateNotificationState(for characteristic: CharacteristicRef, isNotifying: Bool, error: PortError?) -> Bool {
        guard let entry = current, case .setNotify(let enabled) = entry.kind, entry.characteristic == characteristic else { return false }
        if let error {
            finish(entry, .failure(BLEError(failure: GattFailure.status(error, operation: entry.kind.label))))
        } else if isNotifying != enabled {
            finish(entry, .failure(BLEError(failure: BLEFailure(
                code: .gattOperationCallbackMismatch,
                message: "\(entry.kind.label) 응답의 알림 상태(\(isNotifying))가 요청과 다르다"
            ))))
        } else {
            finish(entry, .success(Data()))
        }
        return true
    }

    /// 진행 중인 write 의 조각 하나가 확인됐으면 작업에 넘기고 true
    @discardableResult
    package func didWriteValue(for characteristic: CharacteristicRef, error: PortError?) -> Bool {
        guard let entry = current, entry.kind == .write, entry.characteristic == characteristic, let job = entry.job else { return false }
        job.didWrite(error: error)
        return true
    }

    /// 응답 없는 write 가 멈춰 있으면 다시 보내게 한다
    package func readyToSendWriteWithoutResponse() {
        guard let entry = current, entry.kind == .write else { return }
        entry.job?.readyToSendWithoutResponse()
    }

    // MARK: 폐기

    /// 진행 중인 것과 기다리는 것을 모두 같은 실패로 끝낸다. 연결이 끝날 때와 닫힐 때 쓴다. 큐는 다시 쓸 수 있다
    package func invalidate(_ failure: BLEFailure) {
        deadline?.cancel()
        deadline = nil
        let entries = ([current].compactMap { $0 }) + waiting
        current = nil
        waiting = []
        for entry in entries { complete(entry, .failure(BLEError(failure: failure))) }
    }

    // MARK: 실행

    private func startNextIfIdle() {
        guard current == nil, !waiting.isEmpty else { return }
        let entry = waiting.removeFirst()
        current = entry
        armDeadline(entry)
        entry.start()
    }

    /// 기한을 (다시) 건다. write 는 조각마다 다시 건다: 기한은 조각 하나의 확인 대기 상한이다
    private func armDeadline(_ entry: Entry) {
        deadline?.cancel()
        deadline = Task { @BLECoreActor [weak self, weak entry, clock, timeoutMilliseconds] in
            do { try await clock.sleep(milliseconds: timeoutMilliseconds) } catch { return }
            guard let self, let entry else { return }
            self.deadlineReached(entry)
        }
    }

    private func finish(_ entry: Entry, _ result: Result<Data, BLEError>) {
        guard current === entry else { return }
        deadline?.cancel()
        deadline = nil
        current = nil
        complete(entry, result)
        startNextIfIdle()
    }

    private func complete(_ entry: Entry, _ result: Result<Data, BLEError>) {
        entry.job?.cancel()
        entry.completion?(result)
        entry.waiter.resolve(result.mapError { $0 as any Error })
    }

    /// 기한이 됐다. 바로 판정하지 않고 같은 큐에 판정을 한 번 더 넣는다. 이미 큐에 도착해 있던 완료 콜백이 먼저 처리된다
    private func deadlineReached(_ entry: Entry) {
        guard current === entry else { return }
        Task { @BLECoreActor [weak self, weak entry] in
            guard let self, let entry else { return }
            self.judgeDeadline(entry)
        }
    }

    /// 판정: 그 사이 끝나지 않았을 때만 현재 작업은 `OPERATION_TIMEOUT`, 기다리던 것은 `OPERATION_INVALIDATED`. 세대를 폐기한다(재사용하지 않는다)
    private func judgeDeadline(_ entry: Entry) {
        guard current === entry else { return }
        let failure = GattFailure.timeout(entry.kind.label, milliseconds: timeoutMilliseconds)
        current = nil
        deadline = nil
        let rest = waiting
        waiting = []
        complete(entry, .failure(BLEError(failure: failure)))
        let dropped = GattFailure.invalidated("앞선 작업의 기한 초과로 세대가 폐기됐다")
        for other in rest { complete(other, .failure(BLEError(failure: dropped))) }
        onPoison?(failure)
    }
}
