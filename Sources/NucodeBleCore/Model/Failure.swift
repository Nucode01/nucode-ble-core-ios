import Foundation

// MARK: 실패

/// 코드 하나에 category 하나(contract/failure-codes.json). retryability 는 기본값이고 원인에 따라 실패마다 다를 수 있다.
public struct FailureCategory: Hashable, Sendable {
    public let value: String
    public init(value: String) { self.value = value }

    public static let environment = FailureCategory(value: "environment")
    public static let scan = FailureCategory(value: "scan")
    public static let connection = FailureCategory(value: "connection")
    public static let validation = FailureCategory(value: "validation")
    public static let operation = FailureCategory(value: "operation")
    public static let attribute = FailureCategory(value: "attribute")
    public static let diagnostic = FailureCategory(value: "diagnostic")
}

public enum Retryability: String, Sendable {
    case never = "Never"
    case afterEnvironmentChange = "AfterEnvironmentChange"
    case newConnectionMayHelp = "NewConnectionMayHelp"
    case transientMayHelp = "TransientMayHelp"
    case unknown = "Unknown"
}

/// 공개 실패 코드. wire 값은 `value`. 알 수 없는 새 코드도 값으로 보존하려고 enum 이 아니다.
/// 상수는 iOS 가 내는 코드만 둔다. Android 전용 코드(SCAN_START_FAILED 등)는 상수가 없다.
public struct FailureCode: Hashable, Sendable {
    public let value: String
    public let category: FailureCategory
    public let retryability: Retryability

    public init(value: String, category: FailureCategory, retryability: Retryability) {
        self.value = value
        self.category = category
        self.retryability = retryability
    }

    public static let adapterUnavailable = FailureCode(value: "ADAPTER_UNAVAILABLE", category: .environment, retryability: .afterEnvironmentChange)
    public static let bleUnsupported = FailureCode(value: "BLE_UNSUPPORTED", category: .environment, retryability: .never)
    public static let permissionDenied = FailureCode(value: "PERMISSION_DENIED", category: .environment, retryability: .afterEnvironmentChange)
    public static let scanAlreadyRunning = FailureCode(value: "SCAN_ALREADY_RUNNING", category: .scan, retryability: .never)
    public static let scanStoppedByAdapter = FailureCode(value: "SCAN_STOPPED_BY_ADAPTER", category: .environment, retryability: .afterEnvironmentChange)
    public static let peripheralNotFound = FailureCode(value: "PERIPHERAL_NOT_FOUND", category: .connection, retryability: .transientMayHelp)
    public static let unknownDevice = FailureCode(value: "UNKNOWN_DEVICE", category: .validation, retryability: .never)
    public static let connectDuringDisconnect = FailureCode(value: "CONNECT_DURING_DISCONNECT", category: .connection, retryability: .transientMayHelp)
    public static let connectionOptionsConflict = FailureCode(value: "CONNECTION_OPTIONS_CONFLICT", category: .connection, retryability: .never)
    public static let linkFailed = FailureCode(value: "LINK_FAILED", category: .connection, retryability: .unknown)
    public static let linkTimeout = FailureCode(value: "LINK_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    public static let serviceDiscoveryStartFailed = FailureCode(value: "SERVICE_DISCOVERY_START_FAILED", category: .connection, retryability: .unknown)
    public static let serviceDiscoveryFailed = FailureCode(value: "SERVICE_DISCOVERY_FAILED", category: .connection, retryability: .unknown)
    public static let serviceDiscoveryTimeout = FailureCode(value: "SERVICE_DISCOVERY_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    public static let configurationTimeout = FailureCode(value: "CONFIGURATION_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    public static let disconnectCleanupTimeout = FailureCode(value: "DISCONNECT_CLEANUP_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    public static let duplicateCharacteristicReference = FailureCode(value: "DUPLICATE_CHARACTERISTIC_REFERENCE", category: .connection, retryability: .never)
    public static let notReady = FailureCode(value: "NOT_READY", category: .operation, retryability: .newConnectionMayHelp)
    public static let notConnected = FailureCode(value: "NOT_CONNECTED", category: .connection, retryability: .newConnectionMayHelp)
    public static let characteristicNotFound = FailureCode(value: "CHARACTERISTIC_NOT_FOUND", category: .attribute, retryability: .never)
    public static let gattStatusFailed = FailureCode(value: "GATT_STATUS_FAILED", category: .operation, retryability: .unknown)
    public static let gattOperationCallbackMismatch = FailureCode(value: "GATT_OPERATION_CALLBACK_MISMATCH", category: .operation, retryability: .unknown)
    public static let gattOperationDuplicateCallback = FailureCode(value: "GATT_OPERATION_DUPLICATE_CALLBACK", category: .operation, retryability: .unknown)
    public static let operationTimeout = FailureCode(value: "OPERATION_TIMEOUT", category: .operation, retryability: .newConnectionMayHelp)
    public static let operationInvalidated = FailureCode(value: "OPERATION_INVALIDATED", category: .operation, retryability: .newConnectionMayHelp)
    public static let payloadTooLarge = FailureCode(value: "PAYLOAD_TOO_LARGE", category: .operation, retryability: .never)
    public static let clientClosed = FailureCode(value: "CLIENT_CLOSED", category: .connection, retryability: .never)
    public static let cleanupFailure = FailureCode(value: "CLEANUP_FAILURE", category: .connection, retryability: .never)
    public static let internalTransportError = FailureCode(value: "INTERNAL_TRANSPORT_ERROR", category: .connection, retryability: .unknown)
    public static let gattPayloadObserved = FailureCode(value: "GATT_PAYLOAD_OBSERVED", category: .diagnostic, retryability: .never)

    /// 위 상수 전부. 시험이 failure-codes.json 과 맞춰 본다
    package static let all: [FailureCode] = [
        adapterUnavailable, bleUnsupported, permissionDenied, scanAlreadyRunning, scanStoppedByAdapter,
        peripheralNotFound, unknownDevice, connectDuringDisconnect, connectionOptionsConflict, linkFailed,
        linkTimeout, serviceDiscoveryStartFailed, serviceDiscoveryFailed, serviceDiscoveryTimeout,
        configurationTimeout, disconnectCleanupTimeout, duplicateCharacteristicReference, notReady,
        notConnected, characteristicNotFound, gattStatusFailed, gattOperationCallbackMismatch,
        gattOperationDuplicateCallback, operationTimeout, operationInvalidated, payloadTooLarge,
        clientClosed, cleanupFailure, internalTransportError, gattPayloadObserved,
    ]
}

public struct PlatformDetail: Hashable, Sendable {
    public struct Ios: Hashable, Sendable {
        public let domain: String
        public let code: Int
        public let symbolicName: String?
        public init(domain: String, code: Int, symbolicName: String? = nil) {
            self.domain = domain
            self.code = code
            self.symbolicName = symbolicName
        }
    }

    public let ios: Ios?
    public init(ios: Ios?) { self.ios = ios }
}

public struct BLEFailure: Sendable {
    public let code: FailureCode
    public let message: String
    public let retryability: Retryability
    public let platformDetail: PlatformDetail?

    /// retryability 를 주지 않으면 코드의 기본값
    public init(code: FailureCode, message: String, retryability: Retryability? = nil, platformDetail: PlatformDetail? = nil) {
        self.code = code
        self.message = message
        self.retryability = retryability ?? code.retryability
        self.platformDetail = platformDetail
    }

    public var category: FailureCategory { code.category }
}

public struct BLEError: Error, Sendable {
    public let failure: BLEFailure
    public init(failure: BLEFailure) { self.failure = failure }
}
