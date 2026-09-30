import Foundation

// MARK: 값 객체. 라이브러리 타입을 모른다(번역은 Infrastructure 가 한다)

public struct DeviceId: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    /// 화면용 앞 8자
    public var short: String { String(rawValue.prefix(8)) }
}

public struct DiscoveredDevice: Hashable, Sendable {
    public let id: DeviceId
    public let name: String?
    public let rssi: Int
    public let serviceUUIDs: [String]
    public let lastSeen: Date
    public init(id: DeviceId, name: String?, rssi: Int, serviceUUIDs: [String], lastSeen: Date) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.serviceUUIDs = serviceUUIDs
        self.lastSeen = lastSeen
    }
}

/// 라이브러리 `AdapterState` 의 도메인 거울
public enum AdapterStatus: Hashable, Sendable {
    case unknown
    case unsupported
    case unauthorized(canRequest: Bool)
    case poweredOff
    case resetting
    case ready

    public var label: String {
        switch self {
        case .unknown: "Unknown"
        case .unsupported: "Unsupported"
        case let .unauthorized(canRequest): "Unauthorized(canRequest: \(canRequest))"
        case .poweredOff: "PoweredOff"
        case .resetting: "Resetting"
        case .ready: "Ready"
        }
    }
}

/// `Idle` · `Scanning` · `Idle(Failed:<코드>)` (contract/states.md §7)
public enum ScanStatus: Hashable, Sendable {
    case idle
    case scanning
    case failed(code: String)

    public var label: String {
        switch self {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case let .failed(code): "Idle(Failed:\(code))"
        }
    }
}

/// 연결 상태의 도메인 거울. 표기는 contract/states.md §1 과 같다
public enum LinkState: Hashable, Codable, Sendable {
    case disconnectedInitial
    case disconnectedRequested
    case disconnectedClientClosed
    case disconnectedFailed(code: String)
    case connecting
    case discoveringServices
    case configuring
    case ready
    case disconnecting
    case recovering(code: String)

    public var label: String {
        switch self {
        case .disconnectedInitial: "Disconnected(Initial)"
        case .disconnectedRequested: "Disconnected(Requested)"
        case .disconnectedClientClosed: "Disconnected(ClientClosed)"
        case let .disconnectedFailed(code): "Disconnected(Failed:\(code))"
        case .connecting: "Connecting"
        case .discoveringServices: "DiscoveringServices"
        case .configuring: "Configuring"
        case .ready: "Ready"
        case .disconnecting: "Disconnecting"
        case let .recovering(code): "Recovering(\(code))"
        }
    }

    /// 연결 시도·유지 중이 아니다(Disconnected 계열)
    public var isIdle: Bool {
        switch self {
        case .disconnectedInitial, .disconnectedRequested, .disconnectedClientClosed, .disconnectedFailed: true
        default: false
        }
    }
}

/// 시험 기기 프로필(contract/peripherals/probe.json)에서 앱이 쓰는 characteristic. probe.control 은 러너 전용이라 뺀다
public enum ProbeCharacteristic: String, CaseIterable, Codable, Sendable {
    case probeValue = "probe.value"
    case nusRx = "nus.rx"
    case nusTx = "nus.tx"

    public var serviceUUID: String {
        switch self {
        case .probeValue: ProbeProfile.probeServiceUUID
        case .nusRx, .nusTx: ProbeProfile.nusServiceUUID
        }
    }

    public var uuid: String {
        switch self {
        case .probeValue: "6e7a0002-5c3a-4b8e-9d1f-0a1b2c3d4e5f"
        case .nusRx: "6e400002-b5a3-f393-e0a9-e50e24dcca9e"
        case .nusTx: "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
        }
    }

    /// 소문자 128비트 UUID 로 찾는다. 모르는 것은 nil
    public init?(serviceUUID: String, uuid: String) {
        guard let found = Self.allCases.first(where: {
            $0.uuid == uuid.lowercased() && $0.serviceUUID == serviceUUID.lowercased()
        }) else { return nil }
        self = found
    }
}

public enum ProbeProfile {
    public static let advertisedName = "Nordic_UART_Service"
    public static let nusServiceUUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    public static let probeServiceUUID = "6e7a0001-5c3a-4b8e-9d1f-0a1b2c3d4e5f"
}

/// 스캔 조건. 이름은 광고 local name 앞부분, 서비스는 광고된 UUID(contract/states.md §7)
public enum ScanCriteria: Hashable, Sendable {
    case namePrefix(String)
    case service(uuid: String)

    public var label: String {
        switch self {
        case let .namePrefix(name): "name^=\(name)"
        case let .service(uuid): "service=\(uuid)"
        }
    }
}

/// 앱 시작 등록. 다음 실행의 `start()` 전에 라이브러리에 넘긴다(복원 재실행이 이어받는 연결 의도)
public struct DeviceRegistration: Hashable, Codable, Sendable {
    public let deviceId: DeviceId
    public let autoReconnect: Bool
    public let subscribe: [ProbeCharacteristic]
    public init(deviceId: DeviceId, autoReconnect: Bool, subscribe: [ProbeCharacteristic]) {
        self.deviceId = deviceId
        self.autoReconnect = autoReconnect
        self.subscribe = subscribe
    }
}

/// 게이트웨이 명령 실패. `code` 는 라이브러리 실패 코드 문자열(contract/failure-codes.json) 그대로다
public struct GatewayError: Error, Hashable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public extension Data {
    /// 공백 없는 소문자 16진
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
