import Foundation

// MARK: 스캔

public struct AdvertisementData: Sendable {
    public let localName: String?
    public let serviceUUIDs: Set<BLEUUID>
    public let manufacturerData: [Int: Data]
    public let serviceData: [BLEUUID: Data]
    public let txPower: Int?
    public let isConnectable: Bool?
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

public struct ScanResult: Sendable {
    public let peripheralID: PeripheralID
    public let rssi: Int
    public let advertisement: AdvertisementData
    public init(peripheralID: PeripheralID, rssi: Int, advertisement: AdvertisementData) {
        self.peripheralID = peripheralID
        self.rssi = rssi
        self.advertisement = advertisement
    }
}

public struct ManufacturerDataFilter: Hashable, Sendable {
    public let companyID: Int
    public let data: Data?
    public let mask: Data?
    public init(companyID: Int, data: Data? = nil, mask: Data? = nil) {
        self.companyID = companyID
        self.data = data
        self.mask = mask
    }
}

public struct ServiceDataFilter: Hashable, Sendable {
    public let serviceUUID: BLEUUID
    public let data: Data?
    public let mask: Data?
    public init(serviceUUID: BLEUUID, data: Data? = nil, mask: Data? = nil) {
        self.serviceUUID = serviceUUID
        self.data = data
        self.mask = mask
    }
}

public struct ScanFilter: Hashable, Sendable {
    public let serviceUUIDs: [BLEUUID]
    public let namePrefix: String?
    public let manufacturerData: [ManufacturerDataFilter]
    public let serviceData: [ServiceDataFilter]
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

public enum ScanMode: Hashable, Sendable {
    case lowPower
    case balanced
    case lowLatency
}

public struct ScanOptions: Hashable, Sendable {
    public let mode: ScanMode
    public init(mode: ScanMode = .balanced) { self.mode = mode }
}

public struct ScanRequest: Hashable, Sendable {
    public let filter: ScanFilter
    public let options: ScanOptions
    public init(filter: ScanFilter, options: ScanOptions = ScanOptions()) {
        self.filter = filter
        self.options = options
    }
}

/// `Idle` · `Scanning` · `Idle(Failed:<코드>)` (contract/states.md §8)
public enum ScanState: Sendable {
    case idle
    case scanning
    case failed(BLEFailure)
}
