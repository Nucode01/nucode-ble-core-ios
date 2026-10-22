import Foundation

/// 세션 하나의 peripheral 콜백 입구. 시도(generation)마다 새로 만들어 오래된 시도의 콜백을 걸러 낸다(docs/v1/ios-design.md §5).
/// 세션을 약하게 잡는다: 포트가 이 객체를 붙들어도 세션 수명을 늘리지 않는다.
@BLECoreActor
final class SessionPeripheralDelegate: PeripheralPortDelegate {
    private weak var session: Session?
    private let generation: UInt64

    init(session: Session, generation: UInt64) {
        self.session = session
        self.generation = generation
    }

    func peripheral(_ peripheral: any PeripheralPort, didDiscoverServices services: [ServiceRef], error: PortError?) {
        session?.peripheralDidDiscoverServices(peripheral, generation: generation, services: services, error: error)
    }

    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverCharacteristics characteristics: [DiscoveredCharacteristic],
        for service: ServiceRef,
        error: PortError?
    ) {
        session?.peripheralDidDiscoverCharacteristics(
            peripheral, generation: generation, characteristics: characteristics, for: service, error: error
        )
    }

    func peripheral(_ peripheral: any PeripheralPort, didUpdateValue value: Data?, for characteristic: CharacteristicRef, error: PortError?) {
        session?.peripheralDidUpdateValue(peripheral, generation: generation, value: value, for: characteristic, error: error)
    }

    func peripheral(_ peripheral: any PeripheralPort, didWriteValueFor characteristic: CharacteristicRef, error: PortError?) {
        session?.peripheralDidWriteValue(peripheral, generation: generation, for: characteristic, error: error)
    }

    func peripheral(
        _ peripheral: any PeripheralPort,
        didUpdateNotificationState isNotifying: Bool,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        session?.peripheralDidUpdateNotificationState(
            peripheral, generation: generation, isNotifying: isNotifying, for: characteristic, error: error
        )
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: any PeripheralPort) {
        session?.peripheralIsReadyToWriteWithoutResponse(peripheral, generation: generation)
    }

    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverDescriptors descriptors: [DescriptorRef],
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        session?.peripheralDidDiscoverDescriptors(peripheral, generation: generation, descriptors: descriptors, for: characteristic, error: error)
    }

    func peripheral(_ peripheral: any PeripheralPort, didUpdateValue value: Data?, for descriptor: DescriptorRef, error: PortError?) {
        session?.peripheralDidUpdateDescriptorValue(peripheral, generation: generation, value: value, for: descriptor, error: error)
    }

    func peripheral(_ peripheral: any PeripheralPort, didWriteValueFor descriptor: DescriptorRef, error: PortError?) {
        session?.peripheralDidWriteDescriptorValue(peripheral, generation: generation, for: descriptor, error: error)
    }
}
