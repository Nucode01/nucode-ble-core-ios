import Foundation

// MARK: 쓰기

public enum WriteMode: Hashable, Sendable {
    case withResponse
    case withoutResponse
}

public enum WriteChunking: Hashable, Sendable {
    case automatic
    case disabled
    case fixed(Int)
}

public struct WriteOptions: Hashable, Sendable {
    public let mode: WriteMode
    public let chunking: WriteChunking
    public init(mode: WriteMode = .withResponse, chunking: WriteChunking = .automatic) {
        self.mode = mode
        self.chunking = chunking
    }
}

public enum DeliverySemantics: Hashable, Sendable {
    case remoteAcknowledged
    case submittedToPlatform
}

public struct WriteReceipt: Hashable, Sendable {
    public let bytesCompleted: Int
    public let chunksCompleted: Int
    public let delivery: DeliverySemantics
    public init(bytesCompleted: Int, chunksCompleted: Int, delivery: DeliverySemantics) {
        self.bytesCompleted = bytesCompleted
        self.chunksCompleted = chunksCompleted
        self.delivery = delivery
    }
}
