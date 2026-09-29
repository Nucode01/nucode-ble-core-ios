import Foundation

/// 어댑터 판정의 상태 기계(contract/states.md §6). `(상태, 사건) → (새 상태, 할 일 목록)` 순수 함수다.
/// 입출력·시간·스레드·플랫폼 타입을 쓰지 않는다. 기한은 `armGateDeadline`/`gateDeadlineFired` 로 오간다.
///
/// 할 일 순서: 값이 바뀌면 `publish` 가 먼저, 그 뒤 대기 줄을 요청 순서로 판정한다. 값이 같아도 대기 줄은 다시 판정한다.
package enum AdapterCore {
    package typealias GateID = UInt64

    /// `unknown` 을 기다리는 상한(밀리초)
    package static let unknownWaitLimit = 2000

    /// 플랫폼 라디오 상태. Runtime 이 포트 값을 1:1 로 옮긴다
    package enum Radio: Equatable {
        case unknown
        case resetting
        case unsupported
        case unauthorized
        case poweredOff
        case poweredOn
    }

    package enum Authorization: Equatable {
        case notDetermined
        case restricted
        case denied
        case allowedAlways
    }

    /// 판정을 기다리는 명령 하나
    package struct PendingGate: Equatable {
        package let id: GateID
        package fileprivate(set) var deadlineReached: Bool
    }

    package struct State {
        /// 게시된 값
        package fileprivate(set) var value: AdapterState = .unknown
        /// 대기 줄(먼저 들어온 것이 앞)
        package fileprivate(set) var waiting: [PendingGate] = []
        package fileprivate(set) var lastGateID: GateID = 0
        package fileprivate(set) var isClosed = false

        package init() {}
    }

    package enum Event {
        case usageDescriptionMissing
        /// attach·refresh 공통. 플랫폼에서 읽은 값
        case platform(Radio, Authorization)
        case gateRequested
        /// `authorization` 이 nil 이면 manager 가 없다. 판정 순간의 권한으로 팝업 예외를 본다
        case gateDeadlineFired(GateID, authorization: Authorization?)
        case gateCancelled(GateID)
        case close
    }

    package enum GateOutcome {
        case admitted
        case failed(BLEFailure)
        case cancelled
        case closed
    }

    package enum Effect {
        case publish(AdapterState)
        case armGateDeadline(GateID, milliseconds: Int)
        case finishGate(GateID, GateOutcome)
        case closeStates
    }

    // MARK: 질의

    /// 다음 `gateRequested` 가 받을 판정 id
    package static func nextGateID(_ state: State) -> GateID { state.lastGateID + 1 }

    package static func isClosed(_ state: State) -> Bool { state.isClosed }

    package static func value(_ state: State) -> AdapterState { state.value }

    // MARK: 값 옮김

    package static func map(radio: Radio, authorization: Authorization) -> AdapterState {
        switch authorization {
        case .denied, .restricted:
            return .unauthorized(canRequest: false)
        case .notDetermined, .allowedAlways:
            break
        }
        switch radio {
        case .unknown: return .unknown
        case .resetting: return .resetting
        case .unsupported: return .unsupported
        case .unauthorized: return .unauthorized(canRequest: authorization == .notDetermined)
        case .poweredOff: return .poweredOff
        case .poweredOn: return .ready
        }
    }

    /// 판정 뒤 다시 확인한 값이 Ready 가 아닐 때의 실패
    package static func recheck(_ value: AdapterState) -> BLEFailure? {
        if value == .ready { return nil }
        return leftReady
    }

    /// 판정 뒤 어댑터가 Ready 를 벗어났다(재확인 실패, manager 가 사라진 경우 포함)
    package static let leftReady = BLEFailure(code: .adapterUnavailable, message: "판정 뒤 어댑터가 Ready 를 벗어났다")

    // MARK: 전이

    package static func step(_ state: State, _ event: Event) -> (State, [Effect]) {
        var next = state
        var effects: [Effect] = []
        switch event {
        case .usageDescriptionMissing:
            guard !next.isClosed else { break }
            publish(&next, &effects, .unauthorized(canRequest: false), authorization: nil)
        case .platform(let radio, let authorization):
            guard !next.isClosed else { break }
            publish(&next, &effects, map(radio: radio, authorization: authorization), authorization: authorization)
        case .gateRequested:
            next.lastGateID += 1
            let id = next.lastGateID
            guard !next.isClosed else {
                effects.append(.finishGate(id, .closed))
                break
            }
            if let outcome = verdict(next.value, deadlineReached: false, authorization: nil) {
                effects.append(.finishGate(id, outcome))
            } else {
                next.waiting.append(PendingGate(id: id, deadlineReached: false))
                effects.append(.armGateDeadline(id, milliseconds: unknownWaitLimit))
            }
        case .gateDeadlineFired(let id, let authorization):
            guard !next.isClosed, let index = next.waiting.firstIndex(where: { $0.id == id }) else { break }
            next.waiting[index].deadlineReached = true
            if let outcome = verdict(next.value, deadlineReached: true, authorization: authorization) {
                effects.append(.finishGate(id, outcome))
                next.waiting.remove(at: index)
            }
        case .gateCancelled(let id):
            guard let index = next.waiting.firstIndex(where: { $0.id == id }) else { break }
            next.waiting.remove(at: index)
            effects.append(.finishGate(id, .cancelled))
        case .close:
            guard !next.isClosed else { break }
            next.isClosed = true
            for waiter in next.waiting { effects.append(.finishGate(waiter.id, .closed)) }
            next.waiting.removeAll()
            effects.append(.closeStates)
        }
        return (next, effects)
    }

    // MARK: 내부

    private static func publish(_ state: inout State, _ effects: inout [Effect], _ new: AdapterState, authorization: Authorization?) {
        if new != state.value {
            state.value = new
            effects.append(.publish(new))
        }
        var stillWaiting: [PendingGate] = []
        for waiter in state.waiting {
            if let outcome = verdict(state.value, deadlineReached: waiter.deadlineReached, authorization: authorization) {
                effects.append(.finishGate(waiter.id, outcome))
            } else {
                stillWaiting.append(waiter)
            }
        }
        state.waiting = stillWaiting
    }

    /// 판정표. nil 이면 계속 기다린다.
    /// `unknown` 은 기한이 지났어도 권한 팝업의 답을 기다리는 중(`notDetermined`)이면 계속 기다린다.
    private static func verdict(_ value: AdapterState, deadlineReached: Bool, authorization: Authorization?) -> GateOutcome? {
        switch value {
        case .ready:
            return .admitted
        case .poweredOff:
            return .failed(BLEFailure(code: .adapterUnavailable, message: "Bluetooth 가 꺼져 있다"))
        case .resetting:
            return .failed(BLEFailure(code: .adapterUnavailable, message: "Bluetooth 가 재설정 중이다"))
        case .unauthorized(let canRequest):
            return .failed(BLEFailure(
                code: .permissionDenied,
                message: "Bluetooth 권한이 없다",
                retryability: canRequest ? .afterEnvironmentChange : .never
            ))
        case .unsupported:
            return .failed(BLEFailure(code: .bleUnsupported, message: "이 기기는 BLE central 을 지원하지 않는다"))
        case .unknown:
            if deadlineReached && authorization != .notDetermined {
                return .failed(BLEFailure(code: .adapterUnavailable, message: "어댑터 상태를 \(unknownWaitLimit)ms 안에 알 수 없었다"))
            }
            return nil
        }
    }
}
