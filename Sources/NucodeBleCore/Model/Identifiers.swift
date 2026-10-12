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

/// characteristic 이 광고하는 동작(Android `CharacteristicProperty` 와 같은 5종). 정보 제공용이다.
/// 코어는 이 값으로 read·write·subscribe 를 거르지 않는다(잘못 광고하는 기기도 있다). 거르기는 앱이 정한다
public enum CharacteristicProperty: Hashable, Sendable, CaseIterable {
    case read, writeWithResponse, writeWithoutResponse, notify, indicate
}

public struct GATTCharacteristic: Hashable, Sendable {
    public let ref: CharacteristicRef
    /// 탐색 때 플랫폼이 알려 준 properties. `Hashable` 비교 대상이다: ref 가 같아도 properties 가 다르면 다른 값이다
    public let properties: Set<CharacteristicProperty>
    public init(ref: CharacteristicRef, properties: Set<CharacteristicProperty>) {
        self.ref = ref
        self.properties = properties
    }
}

public struct GATTService: Hashable, Sendable {
    public let ref: ServiceRef
    public let characteristics: [GATTCharacteristic]
    public init(ref: ServiceRef, characteristics: [GATTCharacteristic]) {
        self.ref = ref
        self.characteristics = characteristics
    }
}
