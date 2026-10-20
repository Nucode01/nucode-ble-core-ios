import Foundation

// MARK: 어댑터와 연결 상태

/// 블루투스 어댑터 상태. `BLEClient.adapterStates` 로 받는다
public enum AdapterState: Hashable, Sendable {
    /// 아직 알 수 없다(`start()` 전, 첫 콜백 전)
    case unknown
    /// 이 기기에 BLE 가 없다(시뮬레이터 등)
    case unsupported
    /// 권한이 없다. `canRequest` 가 true 면 사용자가 아직 답하지 않았다.
    /// false 면 거부 · 제한이거나 Info.plist 사용 설명 문구가 없다
    case unauthorized(canRequest: Bool)
    /// 블루투스가 꺼져 있다
    case poweredOff
    /// 블루투스가 재시작 중이다
    case resetting
    /// 쓸 수 있다
    case ready
}

/// `ConnectionState.disconnected` 의 이유
public enum DisconnectReason: Sendable {
    /// 아직 연결을 시도하지 않았다
    case initial
    /// 앱이 `disconnect()` 를 불렀다
    case requested
    /// `BLEClient.close()` 로 끝났다
    case clientClosed
    /// 실패로 끝났다. 원인은 `BLEFailure.code` 로 가린다
    case failed(BLEFailure)
}

/// 세션 하나의 연결 상태. `BLESession.connectionStates` 로 받는다
public enum ConnectionState: Sendable {
    /// 연결 없음
    case disconnected(reason: DisconnectReason)
    /// 기기를 찾고 링크를 맺는 중
    case connecting
    /// 서비스 · characteristic 탐색 중
    case discoveringServices
    /// 구독 의도를 복원하는 중(iOS 에는 MTU 단계가 없다)
    case configuring
    /// read · write · subscribe 를 받는다. 기기 쪽 인증 · handshake 완료를 뜻하지 않는다
    case ready
    /// 해제 정리 중
    case disconnecting
    /// `autoReconnect` 세션이 `ready` 뒤 링크를 잃고 OS 재연결을 기다린다. 기한이 없다: 포기하려면 `disconnect()`
    case recovering(lastFailure: BLEFailure)
}

/// 연결 옵션
public struct ConnectOptions: Hashable, Sendable {
    /// true 면 `ready` 뒤 끊겼을 때 `recovering` 으로 가서 OS 가 다시 붙인다. 링크 기한(15초)도 없다
    public let autoReconnect: Bool
    /// 기본값은 `autoReconnect: false`
    public init(autoReconnect: Bool = false) { self.autoReconnect = autoReconnect }
}
