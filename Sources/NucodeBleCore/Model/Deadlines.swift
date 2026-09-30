import Foundation

/// 기한 기본값(밀리초). Android `BleConfig` 기본값과 같다. 공개하지 않는다(ios-design §16).
package enum Deadlines {
    package static let operation = 5000
    package static let link = 15000
    package static let peripheralScan = 3000
    package static let discovery = 10000
    package static let configuration = 10000
    package static let disconnectCleanup = 5000
    /// 링크 유실 뒤 어댑터 이탈 알림을 기다리는 창(contract/states.md §3). iPhone XR 실측(2026-09-30): 블루투스 끄기에서
    /// didDisconnect 뒤 poweredOff 상태 콜백까지 설정 앱 61·63·87ms, 비행기 모드 250·727ms
    package static let adapterSettle = 1000
}
