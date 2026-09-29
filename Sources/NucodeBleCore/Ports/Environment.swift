import Foundation

/// 실행 환경(Info.plist)에서 읽는 값. xctest 번들에는 사용 설명 키가 없어 시험은 값을 직접 넣는다.
package struct BLEEnvironment: Sendable, Equatable {
    /// `NSBluetoothAlwaysUsageDescription` 이 있고 비어 있지 않다
    package var hasBluetoothUsageDescription: Bool
    /// `UIBackgroundModes`
    package var backgroundModes: Set<String>

    package init(hasBluetoothUsageDescription: Bool, backgroundModes: Set<String> = []) {
        self.hasBluetoothUsageDescription = hasBluetoothUsageDescription
        self.backgroundModes = backgroundModes
    }

    package var hasBluetoothCentralBackgroundMode: Bool { backgroundModes.contains("bluetooth-central") }

    /// 번들의 Info.plist 를 읽는다
    package static func bundle(_ bundle: Bundle = .main) -> BLEEnvironment {
        let info = bundle.infoDictionary ?? [:]
        let usage = (info["NSBluetoothAlwaysUsageDescription"] as? String).map { !$0.isEmpty } ?? false
        let modes = (info["UIBackgroundModes"] as? [String]) ?? []
        return BLEEnvironment(hasBluetoothUsageDescription: usage, backgroundModes: Set(modes))
    }
}
