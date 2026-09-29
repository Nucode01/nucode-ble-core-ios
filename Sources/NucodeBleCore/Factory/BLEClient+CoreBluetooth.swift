import Foundation

extension BLEClient {
    /// CoreBluetooth 로 잇는다. manager 는 `start()` 에서 만든다. 같은 프로세스에서 같은 `restoreIdentifier` 를 두 번 쓰면 trap 한다.
    public convenience init(options: BLEOptions = BLEOptions()) {
        RestoreIdentifierGuard.claimOrTrap(options.restoreIdentifier)
        let identifier = options.restoreIdentifier
        self.init(options: options, environment: .bundle(.main)) {
            CoreBluetoothCentral(restoreIdentifier: identifier)
        }
    }
}
