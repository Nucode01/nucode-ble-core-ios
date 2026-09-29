import CoreBluetooth
import Foundation

/// `CBCentralManager` 를 `CentralPort` 로 잇는다. manager 의 delegate 큐는 core 의 `@BLECoreActor` 실행기와 같은 큐다
/// (docs/v1/ios-design.md §3). delegate 콜백은 `nonisolated` 로 받아 `BLECoreActor.assumeIsolated` 로 동기 처리한다.
/// `Task` 를 쓰지 않으므로 콜백 순서가 그대로 core 에 닿고, `willRestoreState` 는 `didUpdateState` 보다 먼저 처리된다.
@BLECoreActor
final class CoreBluetoothCentral: NSObject, CentralPort, CBCentralManagerDelegate {
    weak var delegate: (any CentralPortDelegate)?

    private var manager: CBCentralManager!
    /// 기기마다 포트 하나를 찾는 약한 조회. 스캔으로 본 기기를 붙들지 않는다(세션이 없는 기기는 쌓이지 않는다)
    private var peripherals: [UUID: WeakPort] = [:]
    /// 연결 중이거나 연결된 기기의 포트만 붙든다(CB 가 delegate 를 약하게 잡는다). 끊기거나 실패하면 놓는다
    private var held: [UUID: CoreBluetoothPeripheral] = [:]

    private struct WeakPort {
        weak var port: CoreBluetoothPeripheral?
    }

    init(restoreIdentifier: String?) {
        super.init()
        var options: [String: Any] = [:]
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        manager = CBCentralManager(delegate: self, queue: bleCoreQueue, options: options.isEmpty ? nil : options)
    }

    var state: CentralPortState {
        switch manager.state {
        case .unknown: .unknown
        case .resetting: .resetting
        case .unsupported: .unsupported
        case .unauthorized: .unauthorized
        case .poweredOff: .poweredOff
        case .poweredOn: .poweredOn
        @unknown default: .unknown
        }
    }

    var authorization: PortAuthorization {
        switch CBCentralManager.authorization {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .denied: .denied
        case .allowedAlways: .allowedAlways
        @unknown default: .notDetermined
        }
    }

    // MARK: CentralPort

    func scanForPeripherals(services: [BLEUUID]?, allowDuplicates: Bool) {
        manager.scanForPeripherals(
            withServices: services?.map { CBUUID(nsuuid: $0.rawValue) },
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates]
        )
    }

    func stopScan() {
        manager.stopScan()
    }

    func retrievePeripherals(withIdentifiers identifiers: [PeripheralID]) -> [any PeripheralPort] {
        let uuids = identifiers.compactMap { UUID(uuidString: $0.rawValue) }
        return manager.retrievePeripherals(withIdentifiers: uuids).map { port(for: $0) }
    }

    func retrieveConnectedPeripherals(withServices services: [BLEUUID]) -> [any PeripheralPort] {
        manager.retrieveConnectedPeripherals(withServices: services.map { CBUUID(nsuuid: $0.rawValue) }).map { port(for: $0) }
    }

    func connect(_ peripheral: any PeripheralPort) {
        guard let port = peripheral as? CoreBluetoothPeripheral else { return }
        held[port.cbPeripheral.identifier] = port
        manager.connect(port.cbPeripheral, options: nil)
    }

    func cancelPeripheralConnection(_ peripheral: any PeripheralPort) {
        guard let port = peripheral as? CoreBluetoothPeripheral else { return }
        manager.cancelPeripheralConnection(port.cbPeripheral)
    }

    private func port(for peripheral: CBPeripheral) -> CoreBluetoothPeripheral {
        if let known = peripherals[peripheral.identifier]?.port, known.cbPeripheral === peripheral { return known }
        if peripherals.count >= 64 { peripherals = peripherals.filter { $0.value.port != nil } }
        let created = CoreBluetoothPeripheral(peripheral)
        peripherals[peripheral.identifier] = WeakPort(port: created)
        return created
    }

    // MARK: 광고 번역

    private static func advertisement(_ data: [String: Any]) -> AdvertisementData {
        var manufacturer: [Int: Data] = [:]
        if let raw = data[CBAdvertisementDataManufacturerDataKey] as? Data, raw.count >= 2 {
            manufacturer[Int(raw[raw.startIndex]) | Int(raw[raw.startIndex + 1]) << 8] = raw.dropFirst(2)
        }
        var serviceData: [BLEUUID: Data] = [:]
        for (key, value) in (data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]) ?? [:] {
            if let uuid = BLEUUID(cbUUID: key) { serviceData[uuid] = value }
        }
        let uuids = ((data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []).compactMap { BLEUUID(cbUUID: $0) }
        return AdvertisementData(
            localName: data[CBAdvertisementDataLocalNameKey] as? String,
            serviceUUIDs: Set(uuids),
            manufacturerData: manufacturer,
            serviceData: serviceData,
            txPower: (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
            isConnectable: (data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
    }

    // MARK: CBCentralManagerDelegate (core 큐에서 온다)

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        BLECoreActor.assumeIsolated {
            delegate?.centralDidUpdateState(self)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        nonisolated(unsafe) let peripheral = peripheral
        nonisolated(unsafe) let data = advertisementData
        let rssi = RSSI.intValue
        BLECoreActor.assumeIsolated {
            delegate?.central(self, didDiscover: port(for: peripheral), advertisement: Self.advertisement(data), rssi: rssi)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        BLECoreActor.assumeIsolated {
            delegate?.central(self, didConnect: port(for: peripheral))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        nonisolated(unsafe) let peripheral = peripheral
        let failure = error.map(PlatformErrorMapping.portError)
        BLECoreActor.assumeIsolated {
            delegate?.central(self, didFailToConnect: port(for: peripheral), error: failure)
            held[peripheral.identifier] = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        nonisolated(unsafe) let peripheral = peripheral
        let failure = error.map(PlatformErrorMapping.portError)
        BLECoreActor.assumeIsolated {
            delegate?.central(self, didDisconnect: port(for: peripheral), error: failure)
            held[peripheral.identifier] = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        nonisolated(unsafe) let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        BLECoreActor.assumeIsolated {
            let ports = restored.map { port(for: $0) }
            for port in ports { held[port.cbPeripheral.identifier] = port }
            delegate?.central(self, willRestoreState: ports)
        }
    }
}
