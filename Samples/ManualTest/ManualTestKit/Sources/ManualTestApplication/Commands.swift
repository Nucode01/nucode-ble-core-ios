import Foundation
import ManualTestDomain

// MARK: 명령 유스케이스. 결과·실패 코드는 모두 기록에 남는다(화면은 기록을 보고 판정한다)

@MainActor
struct CommandRecorder {
    let state: ConsoleState

    /// 성공이면 값, 실패면 기록 뒤 nil
    @discardableResult
    func run<T>(_ command: Command, detail: (T) -> String, _ body: () async throws -> T) async -> T? {
        do {
            let value = try await body()
            state.record(.commandSucceeded(command, detail: detail(value)))
            return value
        } catch let error as GatewayError {
            state.record(.commandFailed(command, code: error.code, message: error.message))
        } catch let error as DomainError {
            state.record(.commandFailed(command, code: error.code, message: "\(error)"))
        } catch {
            state.record(.commandFailed(command, code: "UNEXPECTED", message: "\(error)"))
        }
        return nil
    }
}

@MainActor
public struct StartScan {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction(_ criteria: ScanCriteria) async {
        state.clearDevices()
        await CommandRecorder(state: state).run(.startScan, detail: { _ in criteria.label }) {
            try await gateway.startScan(criteria)
        }
    }
}

@MainActor
public struct StopScan {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction() async {
        await CommandRecorder(state: state).run(.stopScan, detail: { _ in "" }) { await gateway.stopScan() }
    }
}

@MainActor
public struct SelectDevice {
    let state: ConsoleState
    public init(state: ConsoleState) { self.state = state }

    public func callAsFunction(_ id: DeviceId) async {
        await CommandRecorder(state: state).run(.select, detail: { _ in id.rawValue }) {
            try state.mutateSession { session throws(DomainError) in try session.select(id) }
        }
    }
}

@MainActor
public struct SetAutoReconnect {
    let state: ConsoleState
    public init(state: ConsoleState) { self.state = state }

    public func callAsFunction(_ on: Bool) async {
        await CommandRecorder(state: state).run(.setAutoReconnect, detail: { _ in "\(on)" }) {
            try state.mutateSession { session throws(DomainError) in try session.setAutoReconnect(on) }
        }
    }
}

/// 연결 시도를 시작한다. 반환은 "시도가 시작됐다"는 뜻이다(contract/states.md §4)
@MainActor
public struct Connect {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction() async {
        let autoReconnect = state.session.autoReconnect
        await CommandRecorder(state: state).run(.connect, detail: { (id: DeviceId) in "\(id.short) autoReconnect=\(autoReconnect) (시도 시작)" }) {
            let id = try state.session.requireDevice()
            try await gateway.connect(id, autoReconnect: autoReconnect)
            return id
        }
    }
}

@MainActor
public struct Disconnect {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction() async {
        await CommandRecorder(state: state).run(.disconnect, detail: { $0.short }) {
            let id = try state.session.requireDevice()
            await gateway.disconnect(id)
            return id
        }
    }
}

@MainActor
public struct Subscribe {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction(_ characteristic: ProbeCharacteristic = .probeValue) async {
        await CommandRecorder(state: state).run(.subscribe, detail: { _ in characteristic.rawValue }) {
            try await gateway.subscribe(try state.session.requireDevice(), characteristic)
        }
    }
}

@MainActor
public struct Unsubscribe {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction(_ characteristic: ProbeCharacteristic = .probeValue) async {
        await CommandRecorder(state: state).run(.unsubscribe, detail: { _ in characteristic.rawValue }) {
            try await gateway.unsubscribe(try state.session.requireDevice(), characteristic)
        }
    }
}

@MainActor
public struct ReadValue {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction(_ characteristic: ProbeCharacteristic = .probeValue) async {
        await CommandRecorder(state: state).run(.read, detail: { "\(characteristic.rawValue) \($0.hex)" }) {
            try await gateway.read(try state.session.requireDevice(), characteristic)
        }
    }
}

/// NUS rx 에 UTF-8 문자열을 쓴다(응답 있는 쓰기)
@MainActor
public struct WriteNus {
    let gateway: any BleGateway
    let state: ConsoleState
    public init(gateway: any BleGateway, state: ConsoleState) { self.gateway = gateway; self.state = state }

    public func callAsFunction(_ text: String) async {
        await CommandRecorder(state: state).run(.write, detail: { "nus.rx \($0)B \"\(text)\"" }) {
            try await gateway.write(try state.session.requireDevice(), .nusRx, value: Data(text.utf8))
        }
    }
}

/// 현재 대상·정책으로 앱 시작 등록을 저장한다. 다음 실행부터 적용된다(`register` 는 start() 전에만 된다)
@MainActor
public struct SaveRegistration {
    let state: ConsoleState
    let store: any RegistrationStore
    public init(state: ConsoleState, store: any RegistrationStore) { self.state = state; self.store = store }

    public func callAsFunction() async {
        await CommandRecorder(state: state).run(.saveRegistration, detail: { (r: DeviceRegistration) in "\(r.deviceId.short) auto=\(r.autoReconnect) (다음 실행부터)" }) {
            let registration = DeviceRegistration(
                deviceId: try state.session.requireDevice(),
                autoReconnect: state.session.autoReconnect,
                subscribe: [.probeValue]
            )
            try store.save(registration)
            state.set(registration: registration)
            return registration
        }
    }
}

@MainActor
public struct ClearRegistration {
    let state: ConsoleState
    let store: any RegistrationStore
    public init(state: ConsoleState, store: any RegistrationStore) { self.state = state; self.store = store }

    public func callAsFunction() async {
        await CommandRecorder(state: state).run(.clearRegistration, detail: { _ in "(다음 실행부터)" }) {
            try store.save(nil)
            state.set(registration: nil)
        }
    }
}
