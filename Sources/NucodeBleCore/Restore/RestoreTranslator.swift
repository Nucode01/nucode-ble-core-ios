import Foundation

/// 복원을 아는 유일한 코드(docs/v1/ios-design.md §9). `willRestoreState` 를 `didUpdateState` 보다 먼저, 동기로 처리한다.
/// 연결 경로(`linkUp`)는 부르지 않는다: 받아둔 기기는 `poweredOn` 의 연결 경로가 쓴다.
/// 미등록 기기의 연결 취소도 첫 `poweredOn` 까지 미룬다: 복원 콜백 때 manager 는 아직 `unknown` 이라 CoreBluetooth 가
/// 명령을 무시하고(API MISUSE), 세션 없는 OS 연결이 남는다(iPhone XR 실측 2026-09-30).
@BLECoreActor
package final class RestoreTranslator {
    private let registrations: Registrations
    private let registry: SessionRegistry
    private let scanner: BLEScanner
    private let central: () -> (any CentralPort)?
    /// 포트의 delegate 는 약한 참조라 여기서 붙든다
    private var relays: [PeripheralID: RestoredPeripheralRelay] = [:]
    /// 첫 `poweredOn` 에 끊을 미등록 복원 기기. 다른 확정 상태(꺼짐·권한 없음·미지원)가 먼저 오면 명령 없이 버린다
    private var pendingCancels: [any PeripheralPort] = []

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
            } else if let central = central(), central.state == .poweredOn {
                central.cancelPeripheralConnection(peripheral)
            } else {
                pendingCancels.append(peripheral)
            }
        }
        scanner.restore(registered: registrations.scan)
    }

    /// 상태 콜백마다 부른다. `poweredOn` 이면 미룬 취소를 낸다. 그사이 앱이 같은 기기의 세션을 만들었으면 그 세션이
    /// 주인이라 끊지 않는다. 꺼짐·권한 없음·미지원이면 OS 가 이미 링크를 놓았거나 명령이 안 되므로 버린다.
    /// `unknown`·`resetting` 은 계속 기다린다.
    package func centralStateChanged(_ state: CentralPortState) {
        guard !pendingCancels.isEmpty else { return }
        switch state {
        case .poweredOn:
            let pending = pendingCancels
            pendingCancels = []
            guard let central = central() else { return }
            for peripheral in pending where registry.sessions[peripheral.id] == nil {
                central.cancelPeripheralConnection(peripheral)
            }
        case .poweredOff, .unauthorized, .unsupported:
            pendingCancels = []
        case .unknown, .resetting:
            break
        }
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
