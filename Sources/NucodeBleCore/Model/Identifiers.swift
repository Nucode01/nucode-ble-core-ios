import Foundation

// MARK: 식별자와 GATT 참조

/// 기기를 가리키는 불투명한 ID. iOS 에서는 이 앱에게 기기가 보이는 UUID 문자열(`CBPeripheral.identifier`)이다.
/// MAC 주소가 아니고, 같은 기기라도 앱 · 폰마다 다르다
public struct PeripheralID: Hashable, Sendable {
    /// 저장할 때 쓰는 문자열
    public let rawValue: String
    /// 저장해 둔 `rawValue` 로 되살린다
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// 128비트 UUID. 16·32비트 짧은 형식은 Bluetooth base UUID 로 넓히고, 문자열은 소문자로 정규화한다.
public struct BLEUUID: Hashable, Sendable, CustomStringConvertible {
    /// 128비트 값
    public let rawValue: UUID
    /// `UUID` 로 만든다
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
    /// `string` 과 같다
    public var description: String { string }
}

/// 서비스 참조. 값이라 연결 전에 만들어 둘 수 있다
public struct ServiceRef: Hashable, Sendable {
    /// 서비스 UUID
    public let uuid: BLEUUID
    /// 같은 UUID 서비스 중 몇 번째인가(탐색 순서, 0부터). 대부분 0 이다
    public let instanceIndex: Int
    /// 참조를 만든다
    public init(uuid: BLEUUID, instanceIndex: Int) {
        self.uuid = uuid
        self.instanceIndex = instanceIndex
    }
}

/// characteristic 참조. 값이라 연결 전에 만들어 둘 수 있고 재연결 뒤에도 그대로 쓴다.
/// 탐색 결과에 없는 참조로 명령하면 `CHARACTERISTIC_NOT_FOUND`
public struct CharacteristicRef: Hashable, Sendable {
    /// 속한 서비스
    public let service: ServiceRef
    /// characteristic UUID
    public let uuid: BLEUUID
    /// 그 서비스 안에서 같은 UUID characteristic 중 몇 번째인가(0부터). 대부분 0 이다
    public let instanceIndex: Int
    /// 참조를 만든다
    public init(service: ServiceRef, uuid: BLEUUID, instanceIndex: Int) {
        self.service = service
        self.uuid = uuid
        self.instanceIndex = instanceIndex
    }
}

/// characteristic 이 광고하는 동작(Android `CharacteristicProperty` 와 같은 5종). 정보 제공용이다.
/// 코어는 이 값으로 read·write·subscribe 를 거르지 않는다(잘못 광고하는 기기도 있다). 거르기는 앱이 정한다
public enum CharacteristicProperty: Hashable, Sendable, CaseIterable {
    /// 차례로 읽기 · 응답 있는 쓰기 · 응답 없는 쓰기 · notify · indicate 를 광고한다
    case read, writeWithResponse, writeWithoutResponse, notify, indicate
}

/// 탐색된 characteristic
public struct GATTCharacteristic: Hashable, Sendable {
    /// 명령에 쓰는 참조
    public let ref: CharacteristicRef
    /// 탐색 때 플랫폼이 알려 준 properties. `Hashable` 비교 대상이다: ref 가 같아도 properties 가 다르면 다른 값이다
    public let properties: Set<CharacteristicProperty>
    /// 시험 · 가짜 구현용. 라이브러리는 탐색 결과에서 만든다
    public init(ref: CharacteristicRef, properties: Set<CharacteristicProperty>) {
        self.ref = ref
        self.properties = properties
    }
}

/// 탐색된 서비스
public struct GATTService: Hashable, Sendable {
    /// 서비스 참조
    public let ref: ServiceRef
    /// 이 서비스의 characteristic(탐색 순서)
    public let characteristics: [GATTCharacteristic]
    /// 시험 · 가짜 구현용. 라이브러리는 탐색 결과에서 만든다
    public init(ref: ServiceRef, characteristics: [GATTCharacteristic]) {
        self.ref = ref
        self.characteristics = characteristics
    }
}
