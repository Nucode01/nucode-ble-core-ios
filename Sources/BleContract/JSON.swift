import Foundation

/// 계약 파일을 읽다 만난 문제. 메시지에 파일과 JSON 경로를 담는다
public struct ContractError: Error, CustomStringConvertible, Sendable, Equatable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// 엄격한 로더용 JSON 값. Codable 기본 동작은 모르는 키를 조용히 버리고 키 순서를 잃으므로 `JSONParser` 로 트리를 받아 직접 검사한다
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONFields)

    static func parse(_ data: Data, source: String) throws -> JSONValue {
        do {
            return try JSONParser.parse(data)
        } catch {
            throw ContractError("\(source): invalid JSON (\(error))")
        }
    }

    /// 하위 값을 다시 파일 내용처럼 읽히게 한다(형식 시험 사례가 실제 파일과 같은 읽기 경로를 타게 한다)
    func serialized() throws -> Data {
        var out = ""
        try write(to: &out)
        return Data(out.utf8)
    }

    private func write(to out: inout String) throws {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += String(d)
        case .string(let s):
            let data = try JSONSerialization.data(withJSONObject: [s], options: [])
            let arr = String(decoding: data, as: UTF8.self)
            out += String(arr.dropFirst().dropLast())
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                try v.write(to: &out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, k) in o.keys.enumerated() {
                if i > 0 { out += "," }
                try JSONValue.string(k).write(to: &out)
                out += ":"
                try o.values[k]!.write(to: &out)
            }
            out += "}"
        }
    }

    var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .int: "integer"
        case .double: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

/// JSON 객체 하나와 그 경로. 모든 접근자는 타입이 틀리면 경로를 담아 던진다
struct JSONObject {
    let fields: [String: JSONValue]
    /// 파일에 적힌 키 순서
    let keys: [String]
    let path: String

    init(_ value: JSONValue, path: String) throws {
        guard case .object(let object) = value else {
            throw ContractError("\(path): expected object, got \(value.typeName)")
        }
        self.fields = object.values
        self.keys = object.keys
        self.path = path
    }

    func only(_ allowed: Set<String>) throws {
        let unknown = Set(fields.keys).subtracting(allowed).sorted()
        if !unknown.isEmpty {
            throw ContractError("\(path): unknown key(s) \(unknown.map { "\"\($0)\"" }.joined(separator: ", "))")
        }
    }

    func has(_ key: String) -> Bool { fields[key] != nil }

    private func require(_ key: String) throws -> JSONValue {
        guard let v = fields[key] else { throw ContractError("\(path): missing required key \"\(key)\"") }
        return v
    }

    private func mismatch(_ key: String, _ expected: String, _ v: JSONValue) -> ContractError {
        ContractError("\(path).\(key): expected \(expected), got \(v.typeName)")
    }

    func string(_ key: String) throws -> String {
        let v = try require(key)
        guard case .string(let s) = v else { throw mismatch(key, "string", v) }
        return s
    }

    func optionalString(_ key: String) throws -> String? {
        has(key) ? try string(key) : nil
    }

    func int(_ key: String) throws -> Int {
        let v = try require(key)
        guard case .int(let i) = v else { throw mismatch(key, "integer", v) }
        return i
    }

    func optionalInt(_ key: String) throws -> Int? {
        has(key) ? try int(key) : nil
    }

    func bool(_ key: String) throws -> Bool {
        let v = try require(key)
        guard case .bool(let b) = v else { throw mismatch(key, "boolean", v) }
        return b
    }

    func optionalBool(_ key: String) throws -> Bool? {
        has(key) ? try bool(key) : nil
    }

    func array(_ key: String) throws -> [JSONValue] {
        let v = try require(key)
        guard case .array(let a) = v else { throw mismatch(key, "array", v) }
        return a
    }

    func stringArray(_ key: String) throws -> [String] {
        try array(key).enumerated().map { i, v in
            guard case .string(let s) = v else {
                throw ContractError("\(path).\(key)[\(i)]: expected string, got \(v.typeName)")
            }
            return s
        }
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        has(key) ? try stringArray(key) : nil
    }

    func object(_ key: String) throws -> JSONObject {
        try JSONObject(try require(key), path: "\(path).\(key)")
    }
}

/// 짝수 길이 16진수 문자열을 바이트로. write 의 `hex`, descriptor 의 `value`·`hex`가 쓴다
func parseHex(_ hex: String, path: String) throws -> [UInt8] {
    let digits = Array(hex.utf8)
    // UInt8(_:radix:)는 "+f" 같은 부호를 받아 주므로 글자를 먼저 거른다
    guard digits.count % 2 == 0, digits.allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }) else {
        throw ContractError("\(path): invalid hex \"\(hex)\"")
    }
    return stride(from: 0, to: digits.count, by: 2).map { i in
        UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16)!
    }
}
