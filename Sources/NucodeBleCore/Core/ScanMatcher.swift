import Foundation

/// 콜백에서 하는 스캔 필터 판정(docs/v1/api-contract.md "scan 계약").
/// `serviceUUIDs`·`manufacturerData`·`serviceData` 의 모든 항목은 OR 이고, `namePrefix` 만 그 후보에 AND 로 붙는다.
/// 세 목록이 모두 비면 모든 광고가 후보다. 이름은 광고 localName 만 본다(CANDIDATE-19, 캐시된 기기 이름은 쓰지 않는다).
package enum ScanMatcher {
    package static func matches(_ filter: ScanFilter, _ advertisement: AdvertisementData) -> Bool {
        if let prefix = filter.namePrefix {
            guard let name = advertisement.localName, name.hasPrefix(prefix) else { return false }
        }
        let hasAnyItem = !filter.serviceUUIDs.isEmpty || !filter.manufacturerData.isEmpty || !filter.serviceData.isEmpty
        guard hasAnyItem else { return true }
        if filter.serviceUUIDs.contains(where: advertisement.serviceUUIDs.contains) { return true }
        for item in filter.manufacturerData {
            if let payload = advertisement.manufacturerData[item.companyID], prefixMatches(payload, data: item.data, mask: item.mask) {
                return true
            }
        }
        for item in filter.serviceData {
            if let payload = advertisement.serviceData[item.serviceUUID], prefixMatches(payload, data: item.data, mask: item.mask) {
                return true
            }
        }
        return false
    }

    /// `data` 가 없으면 식별자만으로 맞는다. 있으면 payload 의 앞부분이 (mask 가 있으면 mask 를 씌워) 같아야 한다
    private static func prefixMatches(_ payload: Data, data: Data?, mask: Data?) -> Bool {
        guard let data else { return true }
        guard payload.count >= data.count else { return false }
        let payloadBytes = Array(payload)
        let dataBytes = Array(data)
        let maskBytes = mask.map(Array.init)
        for index in dataBytes.indices {
            let m = maskBytes.map { index < $0.count ? $0[index] : 0xFF } ?? 0xFF
            if payloadBytes[index] & m != dataBytes[index] & m { return false }
        }
        return true
    }
}
