import Foundation

// MARK: 이벤트와 스냅샷

public enum BLEEvent: Sendable {
    case connection(peripheralID: PeripheralID, state: ConnectionState)
    case services(peripheralID: PeripheralID, services: [GATTService])
    case subscriptionRestoreFailed(peripheralID: PeripheralID, characteristic: CharacteristicRef, failure: BLEFailure)
    case diagnostic(code: FailureCode, message: String)
}

public struct SessionSnapshot: Sendable {
    public let peripheralID: PeripheralID
    public let state: ConnectionState
    public let services: [GATTService]
    /// 호출자가 원하는 구독 의도. 현재 연결의 CCCD 확인 상태가 아니다(CANDIDATE-18)
    public let subscriptions: Set<CharacteristicRef>
    public init(
        peripheralID: PeripheralID,
        state: ConnectionState,
        services: [GATTService] = [],
        subscriptions: Set<CharacteristicRef> = []
    ) {
        self.peripheralID = peripheralID
        self.state = state
        self.services = services
        self.subscriptions = subscriptions
    }
}

public struct ClientSnapshot: Sendable {
    public let adapter: AdapterState
    public let scanning: Bool
    public let sessions: [SessionSnapshot]
    public init(adapter: AdapterState, scanning: Bool, sessions: [SessionSnapshot]) {
        self.adapter = adapter
        self.scanning = scanning
        self.sessions = sessions
    }
}

/// 생성 옵션. restoreIdentifier 외 필드는 없다(ios-design §3·§9)
public struct BLEOptions: Hashable, Sendable {
    public let restoreIdentifier: String?
    public init(restoreIdentifier: String? = nil) { self.restoreIdentifier = restoreIdentifier }
}
