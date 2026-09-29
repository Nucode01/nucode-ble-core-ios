import Foundation

/// 복원을 아는 유일한 코드(docs/v1/ios-design.md §9). `willRestoreState` 를 `didUpdateState` 보다 먼저, 동기로 처리한다.
/// 연결 경로(`linkUp`)는 부르지 않는다: 받아둔 기기는 `poweredOn` 의 연결 경로가 쓴다.
@BLECoreActor
package final class RestoreTranslator {
    private let registrations: Registrations
    private let registry: SessionRegistry
    private let scanner: BLEScanner
    private let central: () -> (any CentralPort)?
    /// 포트의 delegate 는 약한 참조라 여기서 붙든다
    private var relays: [PeripheralID: RestoredPeripheralRelay] = [:]

    package init(
        registrations: Registrations,
        registry: SessionRegistry,
        scanner: BLEScanner,
        central: @escaping () -> (any CentralPort)?
    ) {
        self.registrations = registrations
        self.registry = registry
        self.scanner = scanner
        self.central = central
    }

    package func willRestoreState(_ peripherals: [any PeripheralPort]) {
        for peripheral in peripherals {
            if registrations.devices[peripheral.id] != nil {
                let session = registry.session(for: peripheral.id)
                session.peripheral = peripheral
                let relay = RestoredPeripheralRelay(id: peripheral.id, registrations: registrations)
                relays[peripheral.id] = relay
                peripheral.delegate = relay
            } else if let central = central() {
                central.cancelPeripheralConnection(peripheral)
            }
        }
        scanner.restore(registered: registrations.scan)
    }
}

/// 연결 경로가 세션 relay 로 바꿔 끼우기 전에 온 값을 handler 로 넘긴다. 복원 직후 앱을 깨운 알림이 여기로 온다
@BLECoreActor
final class RestoredPeripheralRelay: PeripheralPortDelegate {
    private let id: PeripheralID
    private let registrations: Registrations

    init(id: PeripheralID, registrations: Registrations) {
        self.id = id
        self.registrations = registrations
    }

    func peripheral(_ peripheral: any PeripheralPort, didDiscoverServices services: [ServiceRef], error: PortError?) {}
    func peripheral(
        _ peripheral: any PeripheralPort,
        didDiscoverCharacteristics characteristics: [CharacteristicRef],
        for service: ServiceRef,
        error: PortError?
    ) {}

    func peripheral(_ peripheral: any PeripheralPort, didUpdateValue value: Data?, for characteristic: CharacteristicRef, error: PortError?) {
        guard error == nil, let value else { return }
        registrations.deliver(id: id, characteristic: characteristic, value: value)
    }

    func peripheral(_ peripheral: any PeripheralPort, didWriteValueFor characteristic: CharacteristicRef, error: PortError?) {}
    func peripheral(
        _ peripheral: any PeripheralPort,
        didUpdateNotificationState isNotifying: Bool,
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {}
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: any PeripheralPort) {}
}
