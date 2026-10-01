import Foundation

/// 공개 `BLEClient` 를 만든다.
public enum BLEClientFactory {
    /// CoreBluetooth 로 잇는다. manager 는 `start()` 에서 만든다. 같은 프로세스에서 같은 `restoreIdentifier` 를 두 번 쓰면 trap 한다.
    public static func make(options: BLEOptions = BLEOptions()) -> any BLEClient {
        RestoreIdentifierGuard.claimOrTrap(options.restoreIdentifier)
        let identifier = options.restoreIdentifier
        return DefaultBLEClient(options: options, environment: .bundle(.main), clock: ScaledClock.realtime) {
            CoreBluetoothCentral(restoreIdentifier: identifier)
        }
    }
}
