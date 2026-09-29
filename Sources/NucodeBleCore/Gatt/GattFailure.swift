import Foundation

/// GATT 작업의 실패를 공개 실패로 옮기는 곳(전달 계획 CANDIDATE-8). 새 코드는 없다.
enum GattFailure {
    private static let attDomain = "CBATTErrorDomain"

    /// `CBATTError` 의 insufficient* 는 `GATT_STATUS_FAILED` + symbolicName + `AfterEnvironmentChange`. 그 밖은 코드 기본값
    static func status(_ error: PortError, operation: String) -> BLEFailure {
        let symbolicName: String?
        if error.domain == attDomain {
            switch error.code {
            case 5: symbolicName = "GATT_INSUFFICIENT_AUTHENTICATION"
            case 8: symbolicName = "GATT_INSUFFICIENT_AUTHORIZATION"
            case 15: symbolicName = "GATT_INSUFFICIENT_ENCRYPTION"
            default: symbolicName = nil
            }
        } else {
            symbolicName = nil
        }
        return BLEFailure(
            code: .gattStatusFailed,
            message: "\(operation) 실패: \(error.message)",
            retryability: symbolicName == nil ? nil : .afterEnvironmentChange,
            platformDetail: PlatformDetail(ios: .init(domain: error.domain, code: error.code, symbolicName: symbolicName))
        )
    }

    static func invalidated(_ message: String) -> BLEFailure {
        BLEFailure(code: .operationInvalidated, message: message)
    }

    static func timeout(_ operation: String, milliseconds: Int) -> BLEFailure {
        BLEFailure(code: .operationTimeout, message: "\(operation) 이 \(milliseconds)ms 안에 끝나지 않았다")
    }

    static func closed() -> BLEFailure {
        BLEFailure(code: .clientClosed, message: "클라이언트가 닫혔다")
    }
}
