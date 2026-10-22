import Foundation

/// `CBDescriptor.value` → 원본 bytes(api-contract §CBDescriptor.value, 요청서 B.7). CoreBluetooth 는 UUID 마다 다른 Foundation 타입을 준다:
/// 0x2900·0x2902·0x2903 은 `NSNumber`, 0x2901 은 `NSString`, 0x2904 와 그 밖은 `NSData`. 받은 타입으로 가른다.
/// 숫자는 uint16 little-endian 2바이트, 문자열은 UTF-8 이다. 기기가 0x2901 에 UTF-8 이 아닌 bytes 를 넣었으면 원본을 되살릴 수 없다(iOS 한계)
enum DescriptorValueConversion {
    static func bytes(_ value: Any?) -> Data? {
        switch value {
        case let data as Data:
            return data
        case let number as NSNumber:
            return withUnsafeBytes(of: number.uint16Value.littleEndian) { Data($0) }
        case let text as String:
            return Data(text.utf8)
        default:
            return nil
        }
    }
}
