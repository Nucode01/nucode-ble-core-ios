import Foundation

/// 객체의 키를 파일에 적힌 순서대로 지니는 JSON 객체 값. 기기 정의의 descriptor 처럼 순서가 뜻을 갖는 곳이 `keys` 를 쓴다
struct JSONFields: Sendable, Equatable {
    let keys: [String]
    let values: [String: JSONValue]
}

/// 키 순서를 지키는 엄격한 JSON 파서(RFC 8259). `JSONDecoder` 는 객체를 사전으로 읽어 키 순서를 잃는다.
/// 숫자는 지금까지의 읽기와 같게 가른다: 정수로 정확히 나타나는 값(`23`, `23.0`)은 `int`, 그 밖은 `double`.
/// 같은 객체에 키가 겹치면 거부한다
struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0

    static func parse(_ data: Data) throws -> JSONValue {
        var parser = JSONParser(bytes: Array(data))
        parser.skipWhitespace()
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw parser.error("unexpected content after the value") }
        return value
    }

    private init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func error(_ message: String) -> Failure {
        Failure(description: "\(message) at byte \(index)")
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let b = peek, b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { index += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        for b in literal.utf8 {
            guard peek == b else { throw error("expected \"\(literal)\"") }
            index += 1
        }
    }

    private mutating func value() throws -> JSONValue {
        switch peek {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case .some(let b) where b == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b): return try number()
        default: throw error("expected a value")
        }
    }

    private mutating func object() throws -> JSONValue {
        index += 1
        var keys: [String] = []
        var values: [String: JSONValue] = [:]
        skipWhitespace()
        if peek == UInt8(ascii: "}") {
            index += 1
            return .object(JSONFields(keys: keys, values: values))
        }
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\"") else { throw error("expected a string key") }
            let key = try string()
            guard values[key] == nil else { throw error("duplicate key \"\(key)\"") }
            skipWhitespace()
            try expect(":")
            skipWhitespace()
            keys.append(key)
            values[key] = try value()
            skipWhitespace()
            if peek == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect("}")
            return .object(JSONFields(keys: keys, values: values))
        }
    }

    private mutating func array() throws -> JSONValue {
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try value())
            skipWhitespace()
            if peek == UInt8(ascii: ",") {
                index += 1
                continue
            }
            try expect("]")
            return .array(items)
        }
    }

    private mutating func string() throws -> String {
        index += 1
        var out: [UInt8] = []
        while true {
            guard let b = peek else { throw error("unterminated string") }
            index += 1
            switch b {
            case UInt8(ascii: "\""):
                guard let text = String(bytes: out, encoding: .utf8) else { throw error("string is not UTF-8") }
                return text
            case UInt8(ascii: "\\"):
                try escape(into: &out)
            case 0x00..<0x20:
                throw error("control character in string")
            default:
                out.append(b)
            }
        }
    }

    private mutating func escape(into out: inout [UInt8]) throws {
        guard let b = peek else { throw error("unterminated escape") }
        index += 1
        let simple: [UInt8: UInt8] = [
            UInt8(ascii: "\""): 0x22, UInt8(ascii: "\\"): 0x5C, UInt8(ascii: "/"): 0x2F,
            UInt8(ascii: "b"): 0x08, UInt8(ascii: "f"): 0x0C, UInt8(ascii: "n"): 0x0A, UInt8(ascii: "r"): 0x0D, UInt8(ascii: "t"): 0x09,
        ]
        if let mapped = simple[b] {
            out.append(mapped)
            return
        }
        guard b == UInt8(ascii: "u") else { throw error("invalid escape") }
        var scalar = try hex4()
        if (0xD800...0xDBFF).contains(scalar) {
            // 서로게이트 쌍: 뒤에 `\uDC00`~`\uDFFF` 가 와야 한다
            try expect("\\u")
            let low = try hex4()
            guard (0xDC00...0xDFFF).contains(low) else { throw error("invalid surrogate pair") }
            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
        } else if (0xDC00...0xDFFF).contains(scalar) {
            throw error("lone low surrogate")
        }
        guard let unicode = Unicode.Scalar(scalar) else { throw error("invalid unicode escape") }
        out.append(contentsOf: Array(String(Character(unicode)).utf8))
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16),
              bytes[index..<index + 4].allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }) else {
            throw error("invalid unicode escape")
        }
        index += 4
        return value
    }

    private mutating func number() throws -> JSONValue {
        let start = index
        func digits() -> Int {
            let from = index
            while let b = peek, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1 }
            return index - from
        }
        if peek == UInt8(ascii: "-") { index += 1 }
        if peek == UInt8(ascii: "0") {
            index += 1
        } else if digits() == 0 {
            throw error("invalid number")
        }
        var integral = true
        if peek == UInt8(ascii: ".") {
            integral = false
            index += 1
            guard digits() > 0 else { throw error("invalid number") }
        }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            integral = false
            index += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            guard digits() > 0 else { throw error("invalid number") }
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if integral, let int = Int(text) { return .int(int) }
        guard let double = Double(text) else { throw error("invalid number") }
        if let int = Int(exactly: double) { return .int(int) }
        return .double(double)
    }
}
