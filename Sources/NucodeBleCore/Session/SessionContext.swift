import Foundation

/// 세션들이 함께 쓰는 core 부품. 주인은 `BLERuntime` 이고 세션은 빌려 쓴다.
@BLECoreActor
package final class SessionContext {
    package let adapter: AdapterMonitor
    package let scanner: BLEScanner
    package let events: EventHub<BLEEvent>
    package let clock: any BLEClock
    /// 플랫폼 RSSI 요청의 차례. 공개 생성 경로에서는 프로세스 공용이다
    package let rssiTurn: RSSITurn
    /// `start()` 로 manager 가 만들어진 뒤에만 있다. 어댑터 판정이 Ready 이면 있다.
    package var central: (any CentralPort)?

    package init(adapter: AdapterMonitor, scanner: BLEScanner, events: EventHub<BLEEvent>, clock: any BLEClock, rssiTurn: RSSITurn) {
        self.adapter = adapter
        self.scanner = scanner
        self.events = events
        self.clock = clock
        self.rssiTurn = rssiTurn
    }
}
