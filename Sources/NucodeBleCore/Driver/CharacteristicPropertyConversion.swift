import CoreBluetooth

/// `CBCharacteristicProperties` 를 공개 `CharacteristicProperty` 로 옮긴다(Android `mapProperties` 와 같은 5종).
/// broadcast·authenticatedSignedWrites·extendedProperties·*EncryptionRequired 는 버린다. 플랫폼 타입은 Driver 밖으로 나가지 않는다
enum CharacteristicPropertyConversion {
    static let table: [(CBCharacteristicProperties, CharacteristicProperty)] = [
        (.read, .read),
        (.write, .writeWithResponse),
        (.writeWithoutResponse, .writeWithoutResponse),
        (.notify, .notify),
        (.indicate, .indicate),
    ]

    static func properties(_ value: CBCharacteristicProperties) -> Set<CharacteristicProperty> {
        Set(table.filter { value.contains($0.0) }.map(\.1))
    }
}
