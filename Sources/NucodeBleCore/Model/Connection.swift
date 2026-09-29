import Foundation

// MARK: 어댑터와 연결 상태

public enum AdapterState: Hashable, Sendable {
    /// 아직 알 수 없다(`start()` 전, 첫 콜백 전)
    case unknown
    case unsupported
    case unauthorized(canRequest: Bool)
    case poweredOff
    case resetting
    case ready
}

public enum DisconnectReason: Sendable {
    case initial
    case requested
    case clientClosed
    case failed(BLEFailure)
}

public enum ConnectionState: Sendable {
    case disconnected(reason: DisconnectReason)
    case connecting
    case discoveringServices
    case configuring
    case ready
    case disconnecting
    case recovering(lastFailure: BLEFailure)
}

public struct ConnectOptions: Hashable, Sendable {
    public let autoReconnect: Bool
    public init(autoReconnect: Bool = false) { self.autoReconnect = autoReconnect }
}
