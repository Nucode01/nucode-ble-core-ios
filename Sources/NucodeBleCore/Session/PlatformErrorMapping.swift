import Foundation

/// CoreBluetooth 오류(`CBError`·`CBATTError`, 포트에서는 `PortError`)를 공개 실패로 옮기는 곳(CANDIDATE-8).
/// CoreBluetooth 를 import 하지 않아 swift test 가 값만으로 시험한다. GATT 작업 실패는 `GattFailure.status` 가 옮긴다.
enum PlatformErrorMapping {
    static let cbErrorDomain = "CBErrorDomain"
    /// `CBError.peerRemovedPairingInformation`
    static let peerRemovedPairingInformationCode = 14
    static let peerRemovedPairingInformationName = "PEER_REMOVED_PAIRING_INFORMATION"

    /// `didFailToConnect`·`didDisconnect(error)` → `LINK_FAILED`. 원본은 PlatformDetail 에 둔다.
    /// 상대가 페어링 정보를 지운 경우는 symbolicName 과 `AfterEnvironmentChange`(사용자가 본딩을 다시 맺어야 한다)
    static func linkFailure(_ error: PortError?, fallback: String) -> BLEFailure {
        guard let error else { return BLEFailure(code: .linkFailed, message: fallback) }
        let pairingRemoved = error.domain == cbErrorDomain && error.code == peerRemovedPairingInformationCode
        let symbolicName = pairingRemoved ? peerRemovedPairingInformationName : nil
        return BLEFailure(
            code: .linkFailed,
            message: error.message,
            retryability: pairingRemoved ? .afterEnvironmentChange : nil,
            platformDetail: PlatformDetail(ios: .init(domain: error.domain, code: error.code, symbolicName: symbolicName))
        )
    }
}
