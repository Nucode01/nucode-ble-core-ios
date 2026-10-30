import Foundation

/// 플랫폼 RSSI 요청 차례의 Runtime(contract/states.md §8 RSSI 읽기, CANDIDATE-34). GATT 큐 밖이다.
/// 규칙은 `RSSITurnCore` 가 정한다. 여기서는 사건을 넘기고, 새 상태를 먼저 저장한 뒤 할 일(Waiter 결과 · 플랫폼 호출 · 기한)을 순서대로 실행한다.
@BLECoreActor
package final class RSSITurn {
    /// 공개 생성(`BLEClientFactory`)이 쓰는 프로세스 공용 차례
    package static let process = RSSITurn()

    /// 참가자 하나의 호출자 쪽: 기다릴 결과, 그 세션의 플랫폼 호출, 그 세션의 시계(기한)
    private struct Caller {
        let waiter: Waiter<Int>
        let start: @BLECoreActor () -> Void
        let clock: any BLEClock
    }

    private var turn = RSSITurnCore.State()
    private var callers: [UInt64: Caller] = [:]
    private var deadline: Task<Void, Never>?

    package init() {}

    /// 차례 접수. 확인과 접수 사이에 `await` 가 없다. 호출자 취소는 `Waiter.value()` 가 그 호출자만 뗀다
    package func request(
        _ peripheralID: PeripheralID,
        owner: AnyObject,
        clock: any BLEClock,
        start: @escaping @BLECoreActor () -> Void
    ) -> Waiter<Int> {
        var joined: Waiter<Int>?
        dispatch(.request(peripheralID, owner: ObjectIdentifier(owner))) { participant in
            if let existing = self.callers[participant] {
                joined = existing.waiter
            } else {
                let created = Caller(waiter: Waiter<Int>(), start: start, clock: clock)
                self.callers[participant] = created
                joined = created.waiter
            }
        }
        // `joined` 는 request 사건마다 한 번 온다
        return joined!
    }

    /// 플랫폼 결과. 진행 중 요청이 그 기기일 때만 받고 true 를 돌려준다
    @discardableResult
    package func didRead(_ peripheralID: PeripheralID, _ result: Result<Int, BLEError>) -> Bool {
        let outcome: RSSITurnCore.Outcome
        switch result {
        case .success(let value): outcome = .value(value)
        case .failure(let error): outcome = .failure(error.failure)
        }
        return !dispatch(.platformResult(peripheralID, outcome)).contains { if case .unmatched = $0 { true } else { false } }
    }

    /// 그 세션의 참가자만 failure 로 끝낸다
    package func invalidate(_ peripheralID: PeripheralID, owner: AnyObject, _ failure: BLEFailure) {
        dispatch(.invalidate(peripheralID, owner: ObjectIdentifier(owner), failure: failure))
    }

    // MARK: 사건 → 상태 → 할 일

    @discardableResult
    private func dispatch(_ event: RSSITurnCore.Event, joined: (UInt64) -> Void = { _ in }) -> [RSSITurnCore.Effect] {
        let (next, effects) = RSSITurnCore.step(turn, event)
        turn = next
        for effect in effects {
            switch effect {
            case .joined(let participant):
                joined(participant)
            case .send(let participant, let token):
                guard let caller = callers[participant] else { break }
                // 기한을 먼저 건다. 플랫폼이 동기로 답해도 차례가 먼저 끝나고 이 기한은 맞는 요청이 없어 무시된다
                arm(token, clock: caller.clock)
                caller.start()
            case .cancelDeadline:
                deadline?.cancel()
                deadline = nil
            case .resolve(let participant, let outcome):
                guard let caller = callers.removeValue(forKey: participant) else { break }
                switch outcome {
                case .value(let value): caller.waiter.resolve(.success(value))
                case .failure(let failure): caller.waiter.resolve(.failure(BLEError(failure: failure)))
                }
            case .unmatched:
                break
            }
        }
        return effects
    }

    private func arm(_ token: UInt64, clock: any BLEClock) {
        deadline?.cancel()
        deadline = Task { @BLECoreActor [weak self] in
            do { try await clock.sleep(milliseconds: Deadlines.operation) } catch { return }
            self?.dispatch(.deadlineFired(token: token))
        }
    }
}
