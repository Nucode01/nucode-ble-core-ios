import Dispatch
import Foundation

/// 앱 시작 등록(`register`·`registerScan`·`onNotification`)의 보관함. `start()` 전에만 채워진다(docs/v1/ios-design.md §8).
@BLECoreActor
package final class Registrations {
    package struct Device {
        package let id: PeripheralID
        package let options: ConnectOptions
        package let subscribe: [CharacteristicRef]
    }

    private(set) package var devices: [PeripheralID: Device] = [:]
    private(set) package var scan: ScanRequest?
    private var handler: (queue: DispatchQueue, body: @Sendable (PeripheralID, CharacteristicRef, Data) -> Void)?

    package init() {}

    package var orderedDevices: [Device] {
        devices.values.sorted { $0.id.rawValue < $1.id.rawValue }
    }

    package func add(_ device: Device) {
        devices[device.id] = device
    }

    package func setScan(_ request: ScanRequest) {
        scan = request
    }

    package func setHandler(queue: DispatchQueue, _ body: @escaping @Sendable (PeripheralID, CharacteristicRef, Data) -> Void) {
        handler = (queue, body)
    }

    /// 등록된 characteristic 의 알림이면 앱 queue 의 handler 로 넘긴다. 등록 ref 는 공개 ref 라 uuid 로도 맞춘다
    package func deliver(id: PeripheralID, characteristic: CharacteristicRef, value: Data) {
        guard let handler, let device = devices[id] else { return }
        let registered = device.subscribe.first { $0 == characteristic }
            ?? device.subscribe.first { $0.uuid == characteristic.uuid && $0.service.uuid == characteristic.service.uuid }
        guard let registered else { return }
        let body = handler.body
        handler.queue.async { body(id, registered, value) }
    }
}
