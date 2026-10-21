import Foundation

// MARK: 스캔

/// 광고 내용
public struct AdvertisementData: Sendable {
    /// 광고의 local name. 시스템이 캐시한 기기 이름이 아니다
    public let localName: String?
    /// 광고한 service UUID
    public let serviceUUIDs: Set<BLEUUID>
    /// 제조사 데이터. 키는 회사 ID, 값은 회사 ID 뒤의 바이트
    public let manufacturerData: [Int: Data]
    /// service data. 키는 service UUID
    public let serviceData: [BLEUUID: Data]
    /// 광고한 송신 세기(dBm). 광고에 없으면 nil
    public let txPower: Int?
    /// 연결을 받는 광고인가. iOS 가 알려 주지 않으면 nil
    public let isConnectable: Bool?
    /// 시험 · 가짜 구현용. 라이브러리는 스캔 결과에서 만든다
    public init(
        localName: String? = nil,
        serviceUUIDs: Set<BLEUUID> = [],
        manufacturerData: [Int: Data] = [:],
        serviceData: [BLEUUID: Data] = [:],
        txPower: Int? = nil,
        isConnectable: Bool? = nil
    ) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.txPower = txPower
        self.isConnectable = isConnectable
    }
}

/// 스캔 결과 하나. `BLEClient.scanResults` 로 받는다
public struct ScanResult: Sendable {
    /// 연결 · 저장에 그대로 쓰는 기기 ID
    public let peripheralID: PeripheralID
    /// 신호 세기(dBm). CoreBluetooth 값을 그대로 준다(127 은 값 없음)
    public let rssi: Int
    /// 광고 내용
    public let advertisement: AdvertisementData
    /// 시험 · 가짜 구현용. 라이브러리는 스캔 결과에서 만든다
    public init(peripheralID: PeripheralID, rssi: Int, advertisement: AdvertisementData) {
        self.peripheralID = peripheralID
        self.rssi = rssi
        self.advertisement = advertisement
    }
}

/// 제조사 데이터 필터. 라이브러리가 거른다
public struct ManufacturerDataFilter: Hashable, Sendable {
    /// 회사 ID(예: Nordic 0x0059)
    public let companyID: Int
    /// nil 이면 회사 ID 만 맞으면 된다. 있으면 광고 값의 앞부분이 이 값과 같아야 한다
    public let data: Data?
    /// 0 비트 자리는 비교하지 않는다. nil 이거나 `data` 보다 짧으면 남은 자리는 모두 비교한다
    public let mask: Data?
    /// `data` 와 `mask` 는 생략할 수 있다
    public init(companyID: Int, data: Data? = nil, mask: Data? = nil) {
        self.companyID = companyID
        self.data = data
        self.mask = mask
    }
}

/// service data 필터. 라이브러리가 거른다
public struct ServiceDataFilter: Hashable, Sendable {
    /// service UUID
    public let serviceUUID: BLEUUID
    /// nil 이면 UUID 만 맞으면 된다. 있으면 광고 값의 앞부분이 이 값과 같아야 한다
    public let data: Data?
    /// 0 비트 자리는 비교하지 않는다. nil 이거나 `data` 보다 짧으면 남은 자리는 모두 비교한다
    public let mask: Data?
    /// `data` 와 `mask` 는 생략할 수 있다
    public init(serviceUUID: BLEUUID, data: Data? = nil, mask: Data? = nil) {
        self.serviceUUID = serviceUUID
        self.data = data
        self.mask = mask
    }
}

/// 스캔 필터. 라이브러리 판정에서 `serviceUUIDs` · `manufacturerData` · `serviceData` 항목은 서로 OR 이고 `namePrefix` 만 AND 로 붙는다.
/// iOS 한계: `serviceUUIDs` 가 있으면 iOS 가 그 서비스를 광고한 기기만 넘기므로, 제조사 · service data 만 맞는 기기는 보고된다고 보장하지 않는다.
/// 모두 비우면 주변의 모든 광고를 받는다
public struct ScanFilter: Hashable, Sendable {
    /// iOS 가 거른다. 백그라운드 스캔은 이 필터만 동작한다
    public let serviceUUIDs: [BLEUUID]
    /// 광고 local name 의 접두사. 라이브러리가 거른다
    public let namePrefix: String?
    /// 제조사 데이터 필터
    public let manufacturerData: [ManufacturerDataFilter]
    /// service data 필터
    public let serviceData: [ServiceDataFilter]
    /// 모든 항목을 생략할 수 있다
    public init(
        serviceUUIDs: [BLEUUID] = [],
        namePrefix: String? = nil,
        manufacturerData: [ManufacturerDataFilter] = [],
        serviceData: [ServiceDataFilter] = []
    ) {
        self.serviceUUIDs = serviceUUIDs
        self.namePrefix = namePrefix
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
    }
}

/// 스캔 모드. iOS 에는 스캔 세기 설정이 없어 `lowLatency` 만 동작이 다르다
public enum ScanMode: Hashable, Sendable {
    /// `balanced` 와 같다(Android 와 맞춘 값)
    case lowPower
    /// 기본값. 한 기기가 스캔마다 대략 한 번 보고된다
    case balanced
    /// 같은 기기의 광고를 반복 보고한다(RSSI 갱신용). 배터리를 더 쓴다
    case lowLatency
}

/// 스캔 옵션
public struct ScanOptions: Hashable, Sendable {
    /// 스캔 모드
    public let mode: ScanMode
    /// 기본값은 `balanced`
    public init(mode: ScanMode = .balanced) { self.mode = mode }
}

/// `BLEClient.startScan` 요청. 같은 요청으로 다시 시작하면 아무 일 없이 성공하고, 다른 요청이면 `SCAN_ALREADY_RUNNING`
public struct ScanRequest: Hashable, Sendable {
    /// 필터
    public let filter: ScanFilter
    /// 옵션
    public let options: ScanOptions
    /// 옵션 기본값은 `ScanOptions()`
    public init(filter: ScanFilter, options: ScanOptions = ScanOptions()) {
        self.filter = filter
        self.options = options
    }
}

/// `Idle` · `Scanning` · `Idle(Failed:<코드>)` (contract/states.md §8)
public enum ScanState: Sendable {
    /// 스캔하지 않는다
    case idle
    /// 스캔 중
    case scanning
    /// 스캔이 실패로 끝났다(예: 블루투스가 꺼져 `SCAN_STOPPED_BY_ADAPTER`). 자동으로 다시 시작하지 않는다
    case failed(BLEFailure)
}
