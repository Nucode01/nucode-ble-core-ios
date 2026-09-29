import Foundation

/// 플랫폼 광고 값을 공개 `AdvertisementData` 로 옮긴다. CoreBluetooth driver 가 원본 값으로 부른다.
package enum AdvertisementNormalizer {
    /// - Parameters:
    ///   - manufacturerData: `kCBAdvDataManufacturerData` 원본. 앞 2바이트가 company ID(little-endian)다.
    ///     2바이트가 안 되면 버린다.
    package static func normalize(
        localName: String?,
        serviceUUIDs: [BLEUUID],
        manufacturerData: Data?,
        serviceData: [BLEUUID: Data],
        txPower: Int?,
        isConnectable: Bool?
    ) -> AdvertisementData {
        var manufacturer: [Int: Data] = [:]
        if let raw = manufacturerData, raw.count >= 2 {
            let bytes = Array(raw)
            manufacturer[Int(bytes[0]) | (Int(bytes[1]) << 8)] = Data(bytes[2...])
        }
        return AdvertisementData(
            localName: localName,
            serviceUUIDs: Set(serviceUUIDs),
            manufacturerData: manufacturer,
            serviceData: serviceData,
            txPower: txPower,
            isConnectable: isConnectable
        )
    }
}
