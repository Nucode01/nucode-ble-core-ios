import Foundation

/// 세션들이 함께 쓰는 core 부품. 주인은 `BLERuntime` 이고 세션은 빌려 쓴다.
@BLECoreActor
package final class SessionContext {
    package let adapter: AdapterMonitor
    package let scanner: BLEScanner
    package let events: EventHub<BLEEvent>
    package let clock: any BLEClock
    /// `start()` 로 manager 가 만들어진 뒤에만 있다. 어댑터 판정이 Ready 이면 있다.
    package var central: (any CentralPort)?

    package init(adapter: AdapterMonitor, scanner: BLEScanner, events: EventHub<BLEEvent>, clock: any BLEClock) {
        self.adapter = adapter
        self.scanner = scanner
        self.events = events
        self.clock = clock
    }
}

/// 기한 기본값(밀리초). Android `BleConfig` 기본값과 같다. 공개하지 않는다(ios-design §16).
package enum Deadlines {
    package static let operation = 5000
    package static let link = 15000
    package static let peripheralScan = 3000
    package static let discovery = 10000
    package static let configuration = 10000
    package static let disconnectCleanup = 5000
}
