import Foundation

/// 시나리오의 기호 이름(`probe.value`) 하나와 실제 GATT 위치
public struct Characteristic: Sendable, Equatable {
    public let symbol: String
    public let service: String
    public let uuid: String
    public let properties: [String]
    /// 러너만 쓰는 characteristic(기기 제어). 시나리오 호출에는 쓸 수 없다
    public let runnerOnly: Bool
}

/// `peripherals/<이름>.json`
public struct PeripheralProfile: Sendable, Equatable {
    public let name: String
    public let summary: String?
    public let advertisedName: String
    public let characteristics: [String: Characteristic]

    static let knownProperties: Set<String> = ["read", "write", "writeWithoutResponse", "notify", "indicate"]

    /// `expectedName`은 파일 이름(확장자 제외). 내용의 `name`과 같아야 한다
    public static func parse(_ data: Data, expectedName: String) throws -> PeripheralProfile {
        let source = "peripherals/\(expectedName).json"
        let root = try JSONObject(try JSONValue.parse(data, source: source), path: source)
        try root.only(["format", "name", "summary", "advertisedName", "characteristics"])

        let format = try root.int("format")
        guard format == Scenario.formatVersion else {
            throw ContractError("\(source): unsupported format \(format)")
        }
        let name = try root.string("name")
        guard name == expectedName else {
            throw ContractError("\(source): name \"\(name)\" does not match file name \"\(expectedName)\"")
        }

        let chars = try root.object("characteristics")
        var result: [String: Characteristic] = [:]
        for symbol in chars.fields.keys.sorted() {
            let c = try chars.object(symbol)
            try c.only(["service", "uuid", "properties", "runnerOnly"])
            let properties = try c.stringArray("properties")
            if let bad = properties.first(where: { !knownProperties.contains($0) }) {
                throw ContractError("\(c.path).properties: unknown property \"\(bad)\"")
            }
            result[symbol] = Characteristic(
                symbol: symbol,
                service: try c.string("service"),
                uuid: try c.string("uuid"),
                properties: properties,
                runnerOnly: try c.optionalBool("runnerOnly") ?? false
            )
        }

        return PeripheralProfile(
            name: name,
            summary: try root.optionalString("summary"),
            advertisedName: try root.string("advertisedName"),
            characteristics: result
        )
    }
}
