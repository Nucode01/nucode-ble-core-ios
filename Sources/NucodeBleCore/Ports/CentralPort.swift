import Foundation

// MARK: 플랫폼 포트: central
// CBCentralManager 모양이다. 콜백은 모두 core 큐(@BLECoreActor 실행기)에서 온다(docs/v1/ios-design.md §3).

/// `CBManagerState`
package enum CentralPortState: Sendable, Equatable {
    case unknown
    case resetting
    case unsupported
    case unauthorized
    case poweredOff
    case poweredOn
}

/// `CBManagerAuthorization`
package enum PortAuthorization: Sendable, Equatable {
    case notDetermined
    case restricted
    case denied
    case allowedAlways
}

@BLECoreActor
package protocol CentralPortDelegate: AnyObject {
    func centralDidUpdateState(_ central: any CentralPort)
    func central(_ central: any CentralPort, didDiscover peripheral: any PeripheralPort, advertisement: AdvertisementData, rssi: Int)
    func central(_ central: any CentralPort, didConnect peripheral: any PeripheralPort)
    func central(_ central: any CentralPort, didFailToConnect peripheral: any PeripheralPort, error: PortError?)
    func central(_ central: any CentralPort, didDisconnect peripheral: any PeripheralPort, error: PortError?)
    func central(_ central: any CentralPort, willRestoreState peripherals: [any PeripheralPort])
}

@BLECoreActor
package protocol CentralPort: AnyObject {
    var state: CentralPortState { get }
    var authorization: PortAuthorization { get }
    var delegate: (any CentralPortDelegate)? { get set }

    /// 스캔은 하나뿐이다. 다시 부르면 앞 조건을 대체하고 `stopScan` 은 전부 멈춘다.
    func scanForPeripherals(services: [BLEUUID]?, allowDuplicates: Bool)
    func stopScan()
    /// 이 기기가 본 적 있는 식별자만 돌려준다
    func retrievePeripherals(withIdentifiers identifiers: [PeripheralID]) -> [any PeripheralPort]
    func retrieveConnectedPeripherals(withServices services: [BLEUUID]) -> [any PeripheralPort]
    /// 기한이 없다. 기기가 나타나면 붙는다.
    func connect(_ peripheral: any PeripheralPort)
    func cancelPeripheralConnection(_ peripheral: any PeripheralPort)
}
