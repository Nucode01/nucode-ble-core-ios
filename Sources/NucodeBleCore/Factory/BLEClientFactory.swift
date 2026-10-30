import Foundation

/// 공개 `BLEClient` 를 만든다.
public enum BLEClientFactory {
    /// CoreBluetooth 로 잇는다. manager 는 `start()` 에서 만든다. 같은 프로세스에서 같은 `restoreIdentifier` 를 두 번 쓰면 trap 한다.
    /// RSSI 요청 차례는 프로세스 공용이다(states.md §8: 플랫폼 RSSI 요청은 프로세스 전체에서 한 번에 하나)
    public static func make(options: BLEOptions = BLEOptions()) -> any BLEClient {
        RestoreIdentifierGuard.claimOrTrap(options.restoreIdentifier)
        let identifier = options.restoreIdentifier
        return DefaultBLEClient(options: options, environment: .bundle(.main), clock: ScaledClock.realtime, rssiTurn: { RSSITurn.process }) {
            CoreBluetoothCentral(restoreIdentifier: identifier)
        }
    }
}
