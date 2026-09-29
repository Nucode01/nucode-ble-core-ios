import CoreBluetooth
import Foundation

/// `CBPeripheral` 를 `PeripheralPort` 로 잇는다. 기기마다 하나이며 central 이 붙든다(CB 는 delegate 를 약하게 잡는다).
/// CoreBluetooth 는 서비스·characteristic 의 인스턴스 식별자를 주지 않아, 참조는 같은 UUID 사이의 발견 순서로 만든다.
/// delegate 콜백은 core 큐에서 오고 `BLECoreActor.assumeIsolated` 로 동기 처리한다(`Task` 를 쓰지 않는다).
@BLECoreActor
final class CoreBluetoothPeripheral: NSObject, PeripheralPort, CBPeripheralDelegate {
    let cbPeripheral: CBPeripheral
    let id: PeripheralID
    weak var delegate: (any PeripheralPortDelegate)?

    private var services: [ServiceRef: CBService] = [:]
    private var serviceRefs: [ObjectIdentifier: ServiceRef] = [:]
    private var characteristics: [CharacteristicRef: CBCharacteristic] = [:]
    private var characteristicRefs: [ObjectIdentifier: CharacteristicRef] = [:]

    init(_ peripheral: CBPeripheral) {
        cbPeripheral = peripheral
        id = PeripheralID(rawValue: peripheral.identifier.uuidString)
        super.init()
        peripheral.delegate = self
        // 복원된 기기는 이미 서비스를 갖고 있을 수 있다: 복원 직후 알림을 참조로 옮길 수 있어야 한다
        refreshServices()
    }

    var name: String? { cbPeripheral.name }

    var connectionState: PortPeripheralState {
        switch cbPeripheral.state {
        case .disconnected: .disconnected
        case .connecting: .connecting
        case .connected: .connected
        case .disconnecting: .disconnecting
        @unknown default: .disconnected
        }
    }

    var canSendWriteWithoutResponse: Bool { cbPeripheral.canSendWriteWithoutResponse }

    // MARK: PeripheralPort

    func discoverServices(_ serviceUUIDs: [BLEUUID]?) {
        cbPeripheral.discoverServices(serviceUUIDs?.map { CBUUID(nsuuid: $0.rawValue) })
    }

    func discoverCharacteristics(_ characteristicUUIDs: [BLEUUID]?, for service: ServiceRef) {
        guard let cbService = services[service] else {
            failLater { $0.delegate?.peripheral($0, didDiscoverCharacteristics: [], for: service, error: Self.unknownReference) }
            return
        }
        cbPeripheral.discoverCharacteristics(characteristicUUIDs?.map { CBUUID(nsuuid: $0.rawValue) }, for: cbService)
    }

    func readValue(for characteristic: CharacteristicRef) {
        guard let cb = characteristics[characteristic] else {
            failLater { $0.delegate?.peripheral($0, didUpdateValue: nil, for: characteristic, error: Self.unknownReference) }
            return
        }
        cbPeripheral.readValue(for: cb)
    }

    func writeValue(_ data: Data, for characteristic: CharacteristicRef, type: WriteMode) {
        guard let cb = characteristics[characteristic] else {
            if type == .withResponse {
                failLater { $0.delegate?.peripheral($0, didWriteValueFor: characteristic, error: Self.unknownReference) }
            }
            return
        }
        cbPeripheral.writeValue(data, for: cb, type: type == .withResponse ? .withResponse : .withoutResponse)
    }

    func maximumWriteValueLength(for type: WriteMode) -> Int {
        // 응답 있는 write 의 CoreBluetooth 값은 긴 쓰기(prepare write) 한도 512 라서 기기가 거절한다. 설계 §6 대로 MTU - 3 으로 맞춘다
        let withoutResponse = cbPeripheral.maximumWriteValueLength(for: .withoutResponse)
        if type == .withResponse {
            return min(cbPeripheral.maximumWriteValueLength(for: .withResponse), withoutResponse)
        }
        return withoutResponse
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRef) {
        guard let cb = characteristics[characteristic] else {
            failLater { $0.delegate?.peripheral($0, didUpdateNotificationState: !enabled, for: characteristic, error: Self.unknownReference) }
            return
        }
        cbPeripheral.setNotifyValue(enabled, for: cb)
    }

    // MARK: 참조

    private static let unknownReference = PortError(
        domain: "NucodeBleCore", code: -1, message: "플랫폼이 모르는 서비스·characteristic 참조다"
    )

    /// 동기 호출 안에서 delegate 를 다시 부르지 않도록 큐의 다음 턴으로 미룬다
    private func failLater(_ body: @escaping @BLECoreActor (CoreBluetoothPeripheral) -> Void) {
        bleCoreQueue.async { [self] in
            BLECoreActor.assumeIsolated { body(self) }
        }
    }

    /// `peripheral.services` 를 훑어 같은 UUID 사이의 순서로 참조를 다시 만든다
    private func refreshServices() {
        services = [:]
        serviceRefs = [:]
        var seen: [BLEUUID: Int] = [:]
        for service in cbPeripheral.services ?? [] {
            guard let uuid = BLEUUID(cbUUID: service.uuid) else { continue }
            let index = seen[uuid, default: 0]
            seen[uuid] = index + 1
            let ref = ServiceRef(uuid: uuid, instanceIndex: index)
            services[ref] = service
            serviceRefs[ObjectIdentifier(service)] = ref
        }
        characteristics = [:]
        characteristicRefs = [:]
        for (ref, service) in services { refreshCharacteristics(of: service, ref: ref) }
    }

    private func refreshCharacteristics(of service: CBService, ref: ServiceRef) {
        for (old, cb) in characteristics where old.service == ref {
            characteristics[old] = nil
            characteristicRefs[ObjectIdentifier(cb)] = nil
        }
        var seen: [BLEUUID: Int] = [:]
        for item in service.characteristics ?? [] {
            guard let uuid = BLEUUID(cbUUID: item.uuid) else { continue }
            let index = seen[uuid, default: 0]
            seen[uuid] = index + 1
            let characteristic = CharacteristicRef(service: ref, uuid: uuid, instanceIndex: index)
            characteristics[characteristic] = item
            characteristicRefs[ObjectIdentifier(item)] = characteristic
        }
    }

    // MARK: CBPeripheralDelegate (core 큐에서 온다)

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        let failure = error.map(PortErrorConversion.portError)
        BLECoreActor.assumeIsolated {
            refreshServices()
            delegate?.peripheral(self, didDiscoverServices: failure == nil ? orderedServiceRefs() : [], error: failure)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        let failure = error.map(PortErrorConversion.portError)
        nonisolated(unsafe) let service = service
        BLECoreActor.assumeIsolated {
            guard let ref = serviceRefs[ObjectIdentifier(service)] else { return }
            refreshCharacteristics(of: service, ref: ref)
            let found = (service.characteristics ?? []).compactMap { characteristicRefs[ObjectIdentifier($0)] }
            delegate?.peripheral(self, didDiscoverCharacteristics: failure == nil ? found : [], for: ref, error: failure)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let failure = error.map(PortErrorConversion.portError)
        let value = characteristic.value
        nonisolated(unsafe) let characteristic = characteristic
        BLECoreActor.assumeIsolated {
            guard let ref = characteristicRefs[ObjectIdentifier(characteristic)] else { return }
            delegate?.peripheral(self, didUpdateValue: value, for: ref, error: failure)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let failure = error.map(PortErrorConversion.portError)
        nonisolated(unsafe) let characteristic = characteristic
        BLECoreActor.assumeIsolated {
            guard let ref = characteristicRefs[ObjectIdentifier(characteristic)] else { return }
            delegate?.peripheral(self, didWriteValueFor: ref, error: failure)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        let failure = error.map(PortErrorConversion.portError)
        let notifying = characteristic.isNotifying
        nonisolated(unsafe) let characteristic = characteristic
        BLECoreActor.assumeIsolated {
            guard let ref = characteristicRefs[ObjectIdentifier(characteristic)] else { return }
            delegate?.peripheral(self, didUpdateNotificationState: notifying, for: ref, error: failure)
        }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        BLECoreActor.assumeIsolated {
            delegate?.peripheralIsReady(toSendWriteWithoutResponse: self)
        }
    }

    /// CoreBluetooth 가 준 서비스 순서
    private func orderedServiceRefs() -> [ServiceRef] {
        (cbPeripheral.services ?? []).compactMap { serviceRefs[ObjectIdentifier($0)] }
    }
}

extension BLEUUID {
    /// `CBUUID` 의 4·8·36자 표기를 받는다
    init?(cbUUID: CBUUID) {
        self.init(string: cbUUID.uuidString)
    }
}
