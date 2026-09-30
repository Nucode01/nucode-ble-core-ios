import Foundation
import ManualTestDomain
import NucodeBleCore

/// 부패 방지 계층: 라이브러리 타입 ↔ 도메인 타입. 라이브러리 타입은 이 target 밖으로 나가지 않는다
enum Translate {
    static func adapter(_ state: AdapterState) -> AdapterStatus {
        switch state {
        case .unknown: .unknown
        case .unsupported: .unsupported
        case let .unauthorized(canRequest): .unauthorized(canRequest: canRequest)
        case .poweredOff: .poweredOff
        case .resetting: .resetting
        case .ready: .ready
        }
    }

    static func scan(_ state: ScanState) -> ScanStatus {
        switch state {
        case .idle: .idle
        case .scanning: .scanning
        case let .failed(failure): .failed(code: failure.code.value)
        }
    }

    static func link(_ state: ConnectionState) -> LinkState {
        switch state {
        case let .disconnected(reason):
            switch reason {
            case .initial: .disconnectedInitial
            case .requested: .disconnectedRequested
            case .clientClosed: .disconnectedClientClosed
            case let .failed(failure): .disconnectedFailed(code: failure.code.value)
            }
        case .connecting: .connecting
        case .discoveringServices: .discoveringServices
        case .configuring: .configuring
        case .ready: .ready
        case .disconnecting: .disconnecting
        case let .recovering(failure): .recovering(code: failure.code.value)
        }
    }

    static func device(_ result: ScanResult, at: Date) -> DiscoveredDevice {
        DiscoveredDevice(
            id: DeviceId(result.peripheralID.rawValue),
            name: result.advertisement.localName,
            rssi: result.rssi,
            serviceUUIDs: result.advertisement.serviceUUIDs.map(\.string).sorted(),
            lastSeen: at
        )
    }

    static func peripheral(_ id: DeviceId) -> PeripheralID { PeripheralID(rawValue: id.rawValue) }

    /// 시험 기기 프로필은 같은 UUID 인스턴스가 하나라 instanceIndex 는 0 이다
    static func ref(_ characteristic: ProbeCharacteristic) -> CharacteristicRef {
        CharacteristicRef(
            service: ServiceRef(uuid: BLEUUID(string: characteristic.serviceUUID)!, instanceIndex: 0),
            uuid: BLEUUID(string: characteristic.uuid)!,
            instanceIndex: 0
        )
    }

    static func characteristic(_ ref: CharacteristicRef) -> ProbeCharacteristic? {
        ProbeCharacteristic(serviceUUID: ref.service.uuid.string, uuid: ref.uuid.string)
    }

    static func characteristics(_ refs: Set<CharacteristicRef>) -> Set<ProbeCharacteristic> {
        Set(refs.compactMap(characteristic))
    }

    static func criteria(_ criteria: ScanCriteria) -> ScanRequest {
        switch criteria {
        case let .namePrefix(name):
            ScanRequest(filter: ScanFilter(namePrefix: name))
        case let .service(uuid):
            ScanRequest(filter: ScanFilter(serviceUUIDs: BLEUUID(string: uuid).map { [$0] } ?? []))
        }
    }

    static func event(_ event: BLEEvent) -> GatewayEvent {
        switch event {
        case let .connection(id, state):
            .link(DeviceId(id.rawValue), link(state))
        case let .services(id, services):
            .services(DeviceId(id.rawValue), count: services.count)
        case let .subscriptionRestoreFailed(id, ref, failure):
            .subscriptionRestoreFailed(
                DeviceId(id.rawValue),
                characteristic: characteristic(ref)?.rawValue ?? ref.uuid.string,
                code: failure.code.value
            )
        case let .diagnostic(code, message):
            .diagnostic(code: code.value, message: message)
        }
    }

    static func snapshot(_ snapshot: ClientSnapshot) -> GatewaySnapshot {
        GatewaySnapshot(
            adapter: adapter(snapshot.adapter),
            scanning: snapshot.scanning,
            sessions: snapshot.sessions.map {
                ObservedSession(id: DeviceId($0.peripheralID.rawValue), link: link($0.state), subscriptions: characteristics($0.subscriptions))
            }
        )
    }

    /// 라이브러리 오류는 실패 코드 문자열로. 그 밖은 UNEXPECTED
    static func error(_ error: any Error) -> GatewayError {
        if let error = error as? BLEError {
            return GatewayError(code: error.failure.code.value, message: error.failure.message)
        }
        if error is CancellationError { return GatewayError(code: "CANCELLED", message: "") }
        return GatewayError(code: "UNEXPECTED", message: "\(error)")
    }
}
