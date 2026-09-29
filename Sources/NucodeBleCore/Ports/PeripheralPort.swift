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

@BLECoreActor
package protocol PeripheralPortDelegate: AnyObject {
    func peripheral(_ peripheral: any PeripheralPort, didDiscoverServices services: [ServiceRef], error: PortError?)
    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverCharacteristics characteristics: [CharacteristicRef],
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
}
