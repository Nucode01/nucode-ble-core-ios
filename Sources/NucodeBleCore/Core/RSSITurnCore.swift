import Foundation

/// 플랫폼 RSSI 요청의 차례 규칙(contract/states.md §8 RSSI 읽기, CANDIDATE-34). 순수 상태 기계다: 시간 · 동시성 · 플랫폼을 모른다.
/// 차례 상태의 주인은 Runtime(`RSSITurn`)이 든 `State` 하나이고, 바꾸는 곳은 `step` 하나다.
///
/// - 한 번에 요청 하나만 플랫폼에 보낸다. 요청은 기기 하나에 대한 것이고, 세션마다 참가자가 하나씩 있다.
///   같은 기기의 겹친 호출은 대기 · 진행 중 요청에 참가해 그 결과를 나눠 받는다. 다른 기기의 호출은 줄에서 기다린다.
/// - 기한은 보낸 때부터 센다(`send` 뒤 Runtime 이 잰다). 지나면 `RSSI_READ_TIMEOUT` 이고 연결은 건드리지 않는다.
/// - 해제 · close 는 그 세션의 참가자만 끝낸다. 진행 중 요청의 차례는 플랫폼 결과나 기한까지 놓지 않는다.
package enum RSSITurnCore {
    package struct Participant: Equatable, Sendable {
        package let id: UInt64
        package let owner: ObjectIdentifier
        package var resolved = false
    }

    package struct Request: Equatable, Sendable {
        package let token: UInt64
        package let peripheralID: PeripheralID
        /// 들어온 순서
        package var participants: [Participant]
    }

    package struct State: Equatable, Sendable {
        /// 플랫폼에 보낸 요청
        package var current: Request?
        package var waiting: [Request] = []
        package var nextID: UInt64 = 0

        package init() {}
    }

    package enum Outcome: Sendable {
        case value(Int)
        case failure(BLEFailure)
    }

    package enum Event: Sendable {
        case request(PeripheralID, owner: ObjectIdentifier)
        case platformResult(PeripheralID, Outcome)
        case deadlineFired(token: UInt64)
        case invalidate(PeripheralID, owner: ObjectIdentifier, failure: BLEFailure)
    }

    package enum Effect: Sendable {
        /// 이 호출이 기다릴 참가자. `request` 사건마다 하나이고 `send` 보다 먼저 온다
        case joined(participant: UInt64)
        /// 이 참가자의 기기 객체로 플랫폼에 보내고 기한을 잰다
        case send(participant: UInt64, token: UInt64)
        case cancelDeadline
        case resolve(participant: UInt64, Outcome)
        /// 플랫폼 결과가 진행 중 요청의 기기 것이 아니다
        case unmatched
    }

    package static func step(_ state: State, _ event: Event) -> (State, [Effect]) {
        var s = state
        var fx: [Effect] = []
        switch event {
        case .request(let peripheralID, let owner):
            fx.append(.joined(participant: join(&s, peripheralID, owner)))
            startNextIfIdle(&s, &fx)
        case .platformResult(let peripheralID, let outcome):
            guard s.current?.peripheralID == peripheralID else { return (s, [.unmatched]) }
            finish(&s, &fx, outcome)
        case .deadlineFired(let token):
            guard s.current?.token == token else { break }
            finish(&s, &fx, .failure(BLEFailure(
                code: .rssiReadTimeout,
                message: "RSSI 요청이 \(Deadlines.operation)ms 안에 답하지 않았다"
            )))
        case .invalidate(let peripheralID, let owner, let failure):
            if var running = s.current, running.peripheralID == peripheralID {
                for index in running.participants.indices where running.participants[index].owner == owner && !running.participants[index].resolved {
                    running.participants[index].resolved = true
                    fx.append(.resolve(participant: running.participants[index].id, .failure(failure)))
                }
                s.current = running
            }
            for index in s.waiting.indices where s.waiting[index].peripheralID == peripheralID {
                for participant in s.waiting[index].participants where participant.owner == owner {
                    fx.append(.resolve(participant: participant.id, .failure(failure)))
                }
                s.waiting[index].participants.removeAll { $0.owner == owner }
            }
            // 보내지 않은 요청은 참가자가 없으면 줄에서 뺀다
            s.waiting.removeAll { $0.participants.isEmpty }
        }
        return (s, fx)
    }

    /// 진행 중 요청에는 그 세션의 참가가 끝났으면(해제 · close) 붙지 않는다: 옛 링크로 보낸 요청이다
    private static func join(_ s: inout State, _ peripheralID: PeripheralID, _ owner: ObjectIdentifier) -> UInt64 {
        if var running = s.current, running.peripheralID == peripheralID {
            if let mine = running.participants.first(where: { $0.owner == owner }) {
                if !mine.resolved { return mine.id }
            } else {
                let id = nextID(&s)
                running.participants.append(Participant(id: id, owner: owner))
                s.current = running
                return id
            }
        }
        let id = nextID(&s)
        if let index = s.waiting.firstIndex(where: { $0.peripheralID == peripheralID }) {
            // 대기 요청의 참가자는 끝나면 빠지므로 남은 것은 모두 아직 기다린다
            if let mine = s.waiting[index].participants.first(where: { $0.owner == owner }) { return mine.id }
            s.waiting[index].participants.append(Participant(id: id, owner: owner))
            return id
        }
        let token = nextID(&s)
        s.waiting.append(Request(token: token, peripheralID: peripheralID, participants: [Participant(id: id, owner: owner)]))
        return id
    }

    private static func nextID(_ s: inout State) -> UInt64 {
        s.nextID += 1
        return s.nextID
    }

    /// 진행 중으로 먼저 저장한 뒤 결과가 아직 없는 첫 참가자로 보낸다
    private static func startNextIfIdle(_ s: inout State, _ fx: inout [Effect]) {
        guard s.current == nil, !s.waiting.isEmpty else { return }
        let next = s.waiting.removeFirst()
        s.current = next
        if let first = next.participants.first(where: { !$0.resolved }) {
            fx.append(.send(participant: first.id, token: next.token))
        }
    }

    private static func finish(_ s: inout State, _ fx: inout [Effect], _ outcome: Outcome) {
        guard let running = s.current else { return }
        fx.append(.cancelDeadline)
        for participant in running.participants where !participant.resolved {
            fx.append(.resolve(participant: participant.id, outcome))
        }
        s.current = nil
        startNextIfIdle(&s, &fx)
    }
}
