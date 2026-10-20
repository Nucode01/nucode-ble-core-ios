import Foundation

// MARK: 이벤트와 스냅샷

/// 모든 기기의 흐름을 한 줄로 모은 이벤트(로그 · 분석용). `BLEClient.events` 로 받는다
public enum BLEEvent: Sendable {
    /// 세션의 연결 상태가 바뀌었다
    case connection(peripheralID: PeripheralID, state: ConnectionState)
    /// 서비스 탐색 결과가 나왔다
    case services(peripheralID: PeripheralID, services: [GATTService])
    /// 재연결 뒤 구독을 되살리지 못했다. 세션은 그래도 `ready` 로 가지만 이 characteristic 의 알림은 오지 않는다
    case subscriptionRestoreFailed(peripheralID: PeripheralID, characteristic: CharacteristicRef, failure: BLEFailure)
    /// 라이브러리가 처리했지만 기록해 둘 만한 일(늦은 콜백, 해제 정리 시간 초과 등). 앱 동작을 바꿀 신호가 아니다
    case diagnostic(code: FailureCode, message: String)
}

/// 세션 하나의 지금 상태
public struct SessionSnapshot: Sendable {
    /// 기기 ID
    public let peripheralID: PeripheralID
    /// 연결 상태
    public let state: ConnectionState
    /// 마지막 탐색 결과
    public let services: [GATTService]
    /// 호출자가 원하는 구독 의도. 현재 연결의 CCCD 확인 상태가 아니다(CANDIDATE-18)
    public let subscriptions: Set<CharacteristicRef>
    /// 시험 · 가짜 구현용. 라이브러리는 `BLEClient.snapshot()` 에서 만든다
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

/// client 전체의 지금 상태. `BLEClient.snapshot()` 이 준다
public struct ClientSnapshot: Sendable {
    /// 어댑터 상태
    public let adapter: AdapterState
    /// 스캔 중인가
    public let scanning: Bool
    /// 이 client 가 만든 세션 전부. 한 번 만든 세션은 빠지지 않는다
    public let sessions: [SessionSnapshot]
    /// 시험 · 가짜 구현용. 라이브러리는 `BLEClient.snapshot()` 에서 만든다
    public init(adapter: AdapterState, scanning: Bool, sessions: [SessionSnapshot]) {
        self.adapter = adapter
        self.scanning = scanning
        self.sessions = sessions
    }
}

/// 생성 옵션. restoreIdentifier 외 필드는 없다(ios-design §3·§9)
public struct BLEOptions: Hashable, Sendable {
    /// CoreBluetooth 상태 복원 식별자. nil 이면 상태 복원을 쓰지 않는다. 한 프로세스에서 같은 값을 두 번 쓰면 trap 한다
    public let restoreIdentifier: String?
    /// 기본값은 상태 복원 없음
    public init(restoreIdentifier: String? = nil) { self.restoreIdentifier = restoreIdentifier }
}
