import Foundation

// MARK: 플랫폼 포트: peripheral
// CBPeripheral 모양이다. 콜백은 모두 core 큐(@BLECoreActor 실행기)에서 온다(docs/v1/ios-design.md §3).

/// 플랫폼이 준 실패(CBError·CBATTError 대응). 공개 실패로의 번역은 core 가 한다.
package struct PortError: Error, Sendable, Equatable {
    package let domain: String
    package let code: Int
    package let message: String

    package init(domain: String, code: Int, message: String) {
        self.domain = domain
        self.code = code
        self.message = message
    }
}

package enum PortPeripheralState: Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// 탐색한 characteristic 하나. properties 는 플랫폼 값을 Driver 가 공개 타입으로 바꾼 것이다
package struct DiscoveredCharacteristic: Sendable, Equatable {
    package let ref: CharacteristicRef
    package let properties: Set<CharacteristicProperty>

    package init(ref: CharacteristicRef, properties: Set<CharacteristicProperty>) {
        self.ref = ref
        self.properties = properties
    }
}

@BLECoreActor
package protocol PeripheralPortDelegate: AnyObject {
    func peripheral(_ peripheral: any PeripheralPort, didDiscoverServices services: [ServiceRef], error: PortError?)
    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverCharacteristics characteristics: [DiscoveredCharacteristic],
        for service: ServiceRef,
        error: PortError?
    )
    /// read 응답과 알림이 같은 콜백으로 온다(CoreBluetooth 와 같다)
    func peripheral(_ peripheral: any PeripheralPort, didUpdateValue value: Data?, for characteristic: CharacteristicRef, error: PortError?)
    func peripheral(_ peripheral: any PeripheralPort, didWriteValueFor characteristic: CharacteristicRef, error: PortError?)
    func peripheral(
        _ peripheral: any PeripheralPort,
        didUpdateNotificationState isNotifying: Bool,
        for characteristic: CharacteristicRef,
        error: PortError?
    )
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: any PeripheralPort)
    /// 참조는 포트가 만든 것이다(포트의 characteristic 참조 + 같은 UUID 사이 순서). 탐색 순서대로 온다
    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverDescriptors descriptors: [DescriptorRef],
        for characteristic: CharacteristicRef,
        error: PortError?
    )
    /// 값은 원본 bytes 다. Foundation 값을 bytes 로 바꾸는 것은 Driver 몫이다
    func peripheral(_ peripheral: any PeripheralPort, didUpdateValue value: Data?, for descriptor: DescriptorRef, error: PortError?)
    func peripheral(_ peripheral: any PeripheralPort, didWriteValueFor descriptor: DescriptorRef, error: PortError?)
}

@BLECoreActor
package protocol PeripheralPort: AnyObject {
    var id: PeripheralID { get }
    var name: String? { get }
    var connectionState: PortPeripheralState { get }
    var delegate: (any PeripheralPortDelegate)? { get set }
    var canSendWriteWithoutResponse: Bool { get }

    /// 결과는 `didDiscoverServices`. 서비스를 고르지 않는다(`nil`) — 필터링은 core 가 한다.
    func discoverServices(_ serviceUUIDs: [BLEUUID]?)
    func discoverCharacteristics(_ characteristicUUIDs: [BLEUUID]?, for service: ServiceRef)
    func readValue(for characteristic: CharacteristicRef)
    func writeValue(_ data: Data, for characteristic: CharacteristicRef, type: WriteMode)
    func maximumWriteValueLength(for type: WriteMode) -> Int
    func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRef)
    /// 결과는 `didDiscoverDescriptors`
    func discoverDescriptors(for characteristic: CharacteristicRef)
    func readValue(for descriptor: DescriptorRef)
    /// 항상 응답 있는 쓰기다. 결과는 `didWriteValueFor descriptor`
    func writeValue(_ data: Data, for descriptor: DescriptorRef)
}
