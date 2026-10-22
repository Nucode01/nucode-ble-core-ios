import Foundation

/// 시나리오의 기호 이름(`probe.value`) 하나와 실제 GATT 위치
public struct Characteristic: Sendable, Equatable {
    public let symbol: String
    public let service: String
    public let uuid: String
    public let properties: [String]
    /// 러너만 쓰는 characteristic(기기 제어). 시나리오 호출에는 쓸 수 없다
    public let runnerOnly: Bool
    /// descriptor 정의(CANDIDATE-32), 정의 파일에 적힌 순서(sim 가짜 기기의 탐색 순서). 정의 파일에 없으면 비어 있다
    public let descriptors: [DescriptorDefinition]

    /// 이름(`cud`)의 정의. 없으면 nil
    public func descriptor(named name: String) -> DescriptorDefinition? {
        descriptors.first { $0.name == name }
    }
}

/// 기기 정의 `services` 의 항목
public struct Service: Sendable, Equatable {
    public let symbol: String
    public let uuid: String
    /// 기기가 광고(광고 패킷이나 스캔 응답)에 이 UUID 를 넣는가
    public let advertised: Bool
}

/// `peripherals/<이름>.json`
public struct PeripheralProfile: Sendable, Equatable {
    public let name: String
    public let summary: String?
    public let advertisedName: String
    /// 스캔 필터가 쓰는 서비스 기호 이름. 정의 파일에 없으면 비어 있다
    public let services: [String: Service]
    public let characteristics: [String: Characteristic]

    /// `services` 레인이 남길 수 있는 기호 이름 전체(`runnerOnly` 포함)
    public var characteristicSymbols: Set<String> { Set(characteristics.keys) }

    static let knownProperties: Set<String> = ["read", "write", "writeWithoutResponse", "notify", "indicate"]

    /// `expectedName`은 파일 이름(확장자 제외). 내용의 `name`과 같아야 한다
    public static func parse(_ data: Data, expectedName: String) throws -> PeripheralProfile {
        let source = "peripherals/\(expectedName).json"
        let root = try JSONObject(try JSONValue.parse(data, source: source), path: source)
        try root.only(["format", "name", "summary", "advertisedName", "services", "characteristics"])

        let format = try root.int("format")
        guard format == Scenario.formatVersion else {
            throw ContractError("\(source): unsupported format \(format)")
        }
        let name = try root.string("name")
        guard name == expectedName else {
            throw ContractError("\(source): name \"\(name)\" does not match file name \"\(expectedName)\"")
        }

        var services: [String: Service] = [:]
        if root.has("services") {
            let objs = try root.object("services")
            for symbol in objs.fields.keys.sorted() {
                let s = try objs.object(symbol)
                try s.only(["uuid", "advertised"])
                let uuid = try s.string("uuid")
                guard UUID(uuidString: uuid) != nil else {
                    throw ContractError("\(s.path).uuid: not a UUID: \"\(uuid)\"")
                }
                services[symbol] = Service(symbol: symbol, uuid: uuid, advertised: try s.bool("advertised"))
            }
        }

        let chars = try root.object("characteristics")
        var result: [String: Characteristic] = [:]
        for symbol in chars.fields.keys.sorted() {
            let c = try chars.object(symbol)
            try c.only(["service", "uuid", "properties", "runnerOnly", "descriptors"])
            let properties = try c.stringArray("properties")
            if let bad = properties.first(where: { !knownProperties.contains($0) }) {
                throw ContractError("\(c.path).properties: unknown property \"\(bad)\"")
            }
            result[symbol] = Characteristic(
                symbol: symbol,
                service: try c.string("service"),
                uuid: try c.string("uuid"),
                properties: properties,
                runnerOnly: try c.optionalBool("runnerOnly") ?? false,
                descriptors: c.has("descriptors") ? try DescriptorDefinition.parseAll(try c.object("descriptors")) : []
            )
        }

        return PeripheralProfile(
            name: name,
            summary: try root.optionalString("summary"),
            advertisedName: try root.string("advertisedName"),
            services: services,
            characteristics: result
        )
    }
}
