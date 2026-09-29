import Foundation

/// 기한 기본값(밀리초). Android `BleConfig` 기본값과 같다. 공개하지 않는다(ios-design §16).
package enum Deadlines {
    package static let operation = 5000
    package static let link = 15000
    package static let peripheralScan = 3000
    package static let discovery = 10000
    package static let configuration = 10000
    package static let disconnectCleanup = 5000
}
