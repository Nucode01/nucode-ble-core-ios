import Foundation

// MARK: 쓰기

/// 쓰기 방식
public enum WriteMode: Hashable, Sendable {
    /// 응답 있는 쓰기. 조각마다 기기의 확인을 기다린다
    case withResponse
    /// 응답 없는 쓰기. iOS 가 받을 수 있을 때마다 보내고, 흐름 제어는 라이브러리가 한다
    case withoutResponse
}

/// 긴 값을 나누는 방식. 한 번 최대 크기는 연결마다 iOS 가 정한다
public enum WriteChunking: Hashable, Sendable {
    /// 한 번 최대 크기로 자른다
    case automatic
    /// 자르지 않는다. 최대 크기보다 크면 아무것도 보내지 않고 `PAYLOAD_TOO_LARGE`
    case disabled
    /// 주어진 바이트 수로 자른다. 최대 크기보다 크면 아무것도 보내지 않고 `PAYLOAD_TOO_LARGE`
    case fixed(Int)
}

/// `BLESession.write` 옵션
public struct WriteOptions: Hashable, Sendable {
    /// 쓰기 방식
    public let mode: WriteMode
    /// 나누는 방식
    public let chunking: WriteChunking
    /// 기본값은 응답 있는 쓰기와 자동 나누기
    public init(mode: WriteMode = .withResponse, chunking: WriteChunking = .automatic) {
        self.mode = mode
        self.chunking = chunking
    }
}

/// 연결 하나의 방식별 한 번 최대 바이트. 자동 나누기의 조각 크기이고 `.disabled` · `.fixed` 의 한도다.
/// Ready 직전에 정해져 그 연결 동안 바뀌지 않는다(`BLESession.writeLimits`)
public struct WriteLimits: Hashable, Sendable {
    /// 응답 있는 쓰기의 한 번 최대 바이트
    public let withResponse: Int
    /// 응답 없는 쓰기의 한 번 최대 바이트
    public let withoutResponse: Int
    /// 시험 · 가짜 구현용. 라이브러리는 연결이 Ready 가 될 때 만든다
    public init(withResponse: Int, withoutResponse: Int) {
        self.withResponse = withResponse
        self.withoutResponse = withoutResponse
    }

    func maximum(for mode: WriteMode) -> Int {
        switch mode {
        case .withResponse: withResponse
        case .withoutResponse: withoutResponse
        }
    }
}

/// 쓰기 결과가 보장하는 것
public enum DeliverySemantics: Hashable, Sendable {
    /// 기기가 받았다고 확인했다(`.withResponse`)
    case remoteAcknowledged
    /// iOS 에 넘겼다. 기기 도착은 모른다(`.withoutResponse`)
    case submittedToPlatform
}

/// 성공한 쓰기의 결과
public struct WriteReceipt: Hashable, Sendable {
    /// 보낸 바이트 수
    public let bytesCompleted: Int
    /// 보낸 조각 수
    public let chunksCompleted: Int
    /// 결과가 보장하는 것
    public let delivery: DeliverySemantics
    /// 시험 · 가짜 구현용. 라이브러리는 `write` 결과로 만든다
    public init(bytesCompleted: Int, chunksCompleted: Int, delivery: DeliverySemantics) {
        self.bytesCompleted = bytesCompleted
        self.chunksCompleted = chunksCompleted
        self.delivery = delivery
    }
}
