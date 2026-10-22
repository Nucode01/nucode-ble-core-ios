import Foundation

// MARK: 실패

/// 코드 하나에 category 하나(contract/failure-codes.json). retryability 는 기본값이고 원인에 따라 실패마다 다를 수 있다.
public struct FailureCategory: Hashable, Sendable {
    /// wire 값(예: `"connection"`)
    public let value: String
    /// 알 수 없는 category 도 값으로 보존한다
    public init(value: String) { self.value = value }

    /// 블루투스 · 권한 같은 환경
    public static let environment = FailureCategory(value: "environment")
    /// 스캔
    public static let scan = FailureCategory(value: "scan")
    /// 연결
    public static let connection = FailureCategory(value: "connection")
    /// 입력 검사
    public static let validation = FailureCategory(value: "validation")
    /// GATT 작업
    public static let operation = FailureCategory(value: "operation")
    /// characteristic 참조
    public static let attribute = FailureCategory(value: "attribute")
    /// 진단 기록(실패가 아니다)
    public static let diagnostic = FailureCategory(value: "diagnostic")
}

/// 같은 명령을 다시 불러도 되는가
public enum Retryability: String, Sendable {
    /// 고쳐야 한다(참조 · 크기 · 옵션이 틀렸다). 다시 불러도 같다
    case never = "Never"
    /// 블루투스 · 권한이 바뀌면 다시 한다(`adapterStates` 를 본다)
    case afterEnvironmentChange = "AfterEnvironmentChange"
    /// 끊고 다시 연결한 뒤 다시 한다
    case newConnectionMayHelp = "NewConnectionMayHelp"
    /// 잠시 뒤 그대로 다시 한다
    case transientMayHelp = "TransientMayHelp"
    /// 원인을 모른다
    case unknown = "Unknown"
}

/// 공개 실패 코드. wire 값은 `value`. 알 수 없는 새 코드도 값으로 보존하려고 enum 이 아니다.
/// 상수는 iOS 가 내는 코드만 둔다. Android 전용 코드(SCAN_START_FAILED 등)는 상수가 없다.
public struct FailureCode: Hashable, Sendable {
    /// wire 값(예: `"NOT_READY"`). Android 와 같은 문자열이라 로그 · 서버에 남긴다
    public let value: String
    /// 코드의 category
    public let category: FailureCategory
    /// 코드의 기본 retryability. 실패마다 다를 수 있으니 `BLEFailure.retryability` 를 본다
    public let retryability: Retryability

    /// 알 수 없는 코드도 값으로 보존한다
    public init(value: String, category: FailureCategory, retryability: Retryability) {
        self.value = value
        self.category = category
        self.retryability = retryability
    }

    /// 블루투스가 꺼짐 · 재시작 중이거나 상태를 2초 안에 알 수 없다. 연결 중 블루투스가 꺼져도 난다
    public static let adapterUnavailable = FailureCode(value: "ADAPTER_UNAVAILABLE", category: .environment, retryability: .afterEnvironmentChange)
    /// 이 기기에 BLE 가 없다
    public static let bleUnsupported = FailureCode(value: "BLE_UNSUPPORTED", category: .environment, retryability: .never)
    /// 권한이 없다(거부 · 제한 · Info.plist 문구 없음)
    public static let permissionDenied = FailureCode(value: "PERMISSION_DENIED", category: .environment, retryability: .afterEnvironmentChange)
    /// 다른 요청의 스캔이 이미 돈다
    public static let scanAlreadyRunning = FailureCode(value: "SCAN_ALREADY_RUNNING", category: .scan, retryability: .never)
    /// 스캔 중 블루투스가 꺼지거나 권한을 잃어 스캔이 끝났다(`scanStates`)
    public static let scanStoppedByAdapter = FailureCode(value: "SCAN_STOPPED_BY_ADAPTER", category: .environment, retryability: .afterEnvironmentChange)
    /// 저장된 ID 의 기기를 찾지 못했다(`connect` 가 던진다)
    public static let peripheralNotFound = FailureCode(value: "PERIPHERAL_NOT_FOUND", category: .connection, retryability: .transientMayHelp)
    /// 세션이 없는 기기 ID 에 대한 명령. iOS 에서는 나는 경로가 없다(`session(for:)` 가 어떤 ID 에도 세션을 만든다)
    public static let unknownDevice = FailureCode(value: "UNKNOWN_DEVICE", category: .validation, retryability: .never)
    /// 해제 정리 중에 `connect` 를 불렀다
    public static let connectDuringDisconnect = FailureCode(value: "CONNECT_DURING_DISCONNECT", category: .connection, retryability: .transientMayHelp)
    /// 진행 중인 연결과 다른 옵션으로 `connect` 를 불렀다
    public static let connectionOptionsConflict = FailureCode(value: "CONNECTION_OPTIONS_CONFLICT", category: .connection, retryability: .never)
    /// 링크가 실패하거나 끊겼다(`connectionStates`)
    public static let linkFailed = FailureCode(value: "LINK_FAILED", category: .connection, retryability: .unknown)
    /// `autoReconnect: false` 연결이 15초 안에 붙지 않았다
    public static let linkTimeout = FailureCode(value: "LINK_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    /// 서비스 탐색을 시작하지 못했다
    public static let serviceDiscoveryStartFailed = FailureCode(value: "SERVICE_DISCOVERY_START_FAILED", category: .connection, retryability: .unknown)
    /// 서비스 탐색이 실패했다(서비스 0개 포함)
    public static let serviceDiscoveryFailed = FailureCode(value: "SERVICE_DISCOVERY_FAILED", category: .connection, retryability: .unknown)
    /// 서비스 탐색이 10초 안에 끝나지 않았다
    public static let serviceDiscoveryTimeout = FailureCode(value: "SERVICE_DISCOVERY_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    /// 구독 복원이 10초 안에 끝나지 않았다
    public static let configurationTimeout = FailureCode(value: "CONFIGURATION_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    /// 해제 정리가 5초 안에 끝나지 않아 강제로 끝냈다(진단 이벤트)
    public static let disconnectCleanupTimeout = FailureCode(value: "DISCONNECT_CLEANUP_TIMEOUT", category: .connection, retryability: .newConnectionMayHelp)
    /// 탐색 결과에 같은 참조로 가릴 수 없는 characteristic 이 있다(진단 이벤트)
    public static let duplicateCharacteristicReference = FailureCode(value: "DUPLICATE_CHARACTERISTIC_REFERENCE", category: .connection, retryability: .never)
    /// 세션이 `ready` 가 아니다(연결 중 · `recovering` · 끊김 · 링크 유실 직후 1초 포함)
    public static let notReady = FailureCode(value: "NOT_READY", category: .operation, retryability: .newConnectionMayHelp)
    /// 받아들인 작업이 시작하려는 순간 연결이 없다. iOS 에서는 방어용으로만 남아 보통 나지 않는다
    public static let notConnected = FailureCode(value: "NOT_CONNECTED", category: .connection, retryability: .newConnectionMayHelp)
    /// 참조한 characteristic 이나 descriptor 가 탐색 결과에 없다
    public static let characteristicNotFound = FailureCode(value: "CHARACTERISTIC_NOT_FOUND", category: .attribute, retryability: .never)
    /// CCCD(0x2902)에 `writeDescriptor` 했다. iOS 는 CCCD 를 `subscribe`·`unsubscribe` 로만 바꾼다(OS 제약). 아무것도 보내지 않았다
    public static let descriptorWriteNotAllowed = FailureCode(value: "DESCRIPTOR_WRITE_NOT_ALLOWED", category: .attribute, retryability: .never)
    /// 기기가 작업을 거절하거나 실패했다. 권한 · 암호화 부족은 `afterEnvironmentChange`
    public static let gattStatusFailed = FailureCode(value: "GATT_STATUS_FAILED", category: .operation, retryability: .unknown)
    /// 진행 중 작업과 맞지 않는 GATT 콜백이 왔다(진단 이벤트)
    public static let gattOperationCallbackMismatch = FailureCode(value: "GATT_OPERATION_CALLBACK_MISMATCH", category: .operation, retryability: .unknown)
    /// 이미 끝난 작업의 콜백이 다시 왔다(진단 이벤트)
    public static let gattOperationDuplicateCallback = FailureCode(value: "GATT_OPERATION_DUPLICATE_CALLBACK", category: .operation, retryability: .unknown)
    /// 작업이 5초 안에 끝나지 않았다. 연결도 끊는다
    public static let operationTimeout = FailureCode(value: "OPERATION_TIMEOUT", category: .operation, retryability: .newConnectionMayHelp)
    /// 대기 · 진행 중 작업이 해제 · 끊김으로 끝났다
    public static let operationInvalidated = FailureCode(value: "OPERATION_INVALIDATED", category: .operation, retryability: .newConnectionMayHelp)
    /// 나누기를 끄거나 고정 크기가 한 번 최대 크기를 넘었다. 아무것도 보내지 않았다
    public static let payloadTooLarge = FailureCode(value: "PAYLOAD_TOO_LARGE", category: .operation, retryability: .never)
    /// 닫힌 client 에 명령했거나 `close()` 가 대기 중 명령을 끝냈다
    public static let clientClosed = FailureCode(value: "CLIENT_CLOSED", category: .connection, retryability: .never)
    /// `close()` 정리 도중 오류가 났다(진단 이벤트). client 는 그래도 닫힌다
    public static let cleanupFailure = FailureCode(value: "CLEANUP_FAILURE", category: .connection, retryability: .never)
    /// 공개 실패 타입이 아닌 내부 오류를 감쌌다. 나면 라이브러리 결함이다
    public static let internalTransportError = FailureCode(value: "INTERNAL_TRANSPORT_ERROR", category: .connection, retryability: .unknown)
    /// 값 관측 기록(logger 전용, 실패가 아니다). 지금 iOS 코어는 이 코드를 내지 않는다
    public static let gattPayloadObserved = FailureCode(value: "GATT_PAYLOAD_OBSERVED", category: .diagnostic, retryability: .never)

    /// 위 상수 전부. 시험이 failure-codes.json 과 맞춰 본다
    package static let all: [FailureCode] = [
        adapterUnavailable, bleUnsupported, permissionDenied, scanAlreadyRunning, scanStoppedByAdapter,
        peripheralNotFound, unknownDevice, connectDuringDisconnect, connectionOptionsConflict, linkFailed,
        linkTimeout, serviceDiscoveryStartFailed, serviceDiscoveryFailed, serviceDiscoveryTimeout,
        configurationTimeout, disconnectCleanupTimeout, duplicateCharacteristicReference, notReady,
        notConnected, characteristicNotFound, descriptorWriteNotAllowed, gattStatusFailed, gattOperationCallbackMismatch,
        gattOperationDuplicateCallback, operationTimeout, operationInvalidated, payloadTooLarge,
        clientClosed, cleanupFailure, internalTransportError, gattPayloadObserved,
    ]
}

/// 플랫폼의 원래 오류(로그 · 문의용). 분기에는 쓰지 않는다
public struct PlatformDetail: Hashable, Sendable {
    /// CoreBluetooth 원래 오류
    public struct Ios: Hashable, Sendable {
        /// 오류 domain(`CBErrorDomain` · `CBATTErrorDomain` 등)
        public let domain: String
        /// 그 domain 의 코드 값
        public let code: Int
        /// 코드의 이름. 없으면 nil
        public let symbolicName: String?
        /// 원래 오류를 담는다
        public init(domain: String, code: Int, symbolicName: String? = nil) {
            self.domain = domain
            self.code = code
            self.symbolicName = symbolicName
        }
    }

    /// iOS 원래 오류. 없으면 nil
    public let ios: Ios?
    /// 원래 오류를 담는다
    public init(ios: Ios?) { self.ios = ios }
}

/// 실패 하나. 명령은 `BLEError` 로 감싸 던지고, 상태 · 이벤트는 그대로 싣는다
public struct BLEFailure: Sendable {
    /// 분기는 이 값으로 한다
    public let code: FailureCode
    /// 사람용 설명. 버전마다 바뀔 수 있으니 분기하지 않는다
    public let message: String
    /// 이 실패의 retryability. 코드 기본값과 다를 수 있다
    public let retryability: Retryability
    /// 플랫폼 원래 오류. 없으면 nil
    public let platformDetail: PlatformDetail?

    /// retryability 를 주지 않으면 코드의 기본값
    public init(code: FailureCode, message: String, retryability: Retryability? = nil, platformDetail: PlatformDetail? = nil) {
        self.code = code
        self.message = message
        self.retryability = retryability ?? code.retryability
        self.platformDetail = platformDetail
    }

    /// `code.category` 와 같다
    public var category: FailureCategory { code.category }
}

/// 명령이 던지는 오류. 취소된 Task 의 명령은 이것 대신 `CancellationError` 를 던진다
public struct BLEError: Error, Sendable {
    /// 실패 내용
    public let failure: BLEFailure
    /// 실패를 감싼다
    public init(failure: BLEFailure) { self.failure = failure }
}
