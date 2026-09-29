import Foundation

// MARK: 식별자와 GATT 참조

public struct PeripheralID: Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// 128비트 UUID. 16·32비트 짧은 형식은 Bluetooth base UUID 로 넓히고, 문자열은 소문자로 정규화한다.
public struct BLEUUID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }

    /// 4자·8자 16진 짧은 형식 또는 36자 128비트 형식. 그 밖은 nil
    public init?(string: String) {
        let text = string.lowercased()
        switch text.count {
        case 4, 8:
            guard text.allSatisfy(\.isHexDigit) else { return nil }
            let padded = String(repeating: "0", count: 8 - text.count) + text
            self.init(rawValue: UUID(uuidString: padded + "-0000-1000-8000-00805f9b34fb")!)
        case 36:
            guard let uuid = UUID(uuidString: text) else { return nil }
            self.init(rawValue: uuid)
        default:
            return nil
        }
    }

    /// 128비트 소문자 표기
    public var string: String { rawValue.uuidString.lowercased() }
    public var description: String { string }
}

public struct ServiceRef: Hashable, Sendable {
    public let uuid: BLEUUID
    public let instanceIndex: Int
    public init(uuid: BLEUUID, instanceIndex: Int) {
        self.uuid = uuid
        self.instanceIndex = instanceIndex
    }
}

public struct CharacteristicRef: Hashable, Sendable {
    public let service: ServiceRef
    public let uuid: BLEUUID
    public let instanceIndex: Int
    public init(service: ServiceRef, uuid: BLEUUID, instanceIndex: Int) {
        self.service = service
        self.uuid = uuid
        self.instanceIndex = instanceIndex
    }
}

public struct GATTCharacteristic: Hashable, Sendable {
    public let ref: CharacteristicRef
    public init(ref: CharacteristicRef) { self.ref = ref }
}

public struct GATTService: Hashable, Sendable {
    public let ref: ServiceRef
    public let characteristics: [GATTCharacteristic]
    public init(ref: ServiceRef, characteristics: [GATTCharacteristic]) {
        self.ref = ref
        self.characteristics = characteristics
    }
}
