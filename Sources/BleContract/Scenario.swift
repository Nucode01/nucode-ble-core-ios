import Foundation

public enum RunTarget: String, Sendable, CaseIterable {
    case sim, device
}

public enum Platform: String, Sendable, CaseIterable {
    case android, ios
}

public enum ScenarioStatus: String, Sendable {
    case draft, frozen
}

/// `scenarios/<id>.json` 하나. 기호 이름은 로드할 때 peripheral 프로필로 풀어 둔다
public struct Scenario: Sendable, Equatable {
    public static let formatVersion = 1
    public static let defaultTimeoutMs = 15_000

    public let id: String
    public let summary: String
    public let status: ScenarioStatus
    public let runsOn: [RunTarget]
    public let platforms: [Platform]
    public let peripheral: PeripheralProfile
    public let steps: [Step]
    /// 적힌 레인만 판정한다
    public let expect: [Lane: [String]]
    public let diffIgnore: [String]
}

public enum Step: Sendable, Equatable {
    case call(CallStep)
    case wait(AwaitStep)
    case device(DeviceEvent)
    case sleep(ms: Int)
}

public struct CallStep: Sendable, Equatable {
    public let action: CallAction
    /// `async: true`일 때의 이름. nil 이면 동기 호출
    public let asyncName: String?
    public let timeoutMs: Int

    public init(action: CallAction, asyncName: String? = nil, timeoutMs: Int = Scenario.defaultTimeoutMs) {
        self.action = action
        self.asyncName = asyncName
        self.timeoutMs = timeoutMs
    }
}

public enum CallAction: Sendable, Equatable {
    case connect(autoReconnect: Bool)
    case disconnect
    case read(Characteristic)
    case write(Characteristic, bytes: [UInt8], withResponse: Bool)
    case subscribe(Characteristic)
    case unsubscribe(Characteristic)

    /// `result` 레인 항목의 앞부분. `read probe.value`
    public var label: String {
        switch self {
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .read(let c): "read \(c.symbol)"
        case .write(let c, _, _): "write \(c.symbol)"
        case .subscribe(let c): "subscribe \(c.symbol)"
        case .unsubscribe(let c): "unsubscribe \(c.symbol)"
        }
    }
}

public struct AwaitStep: Sendable, Equatable {
    public let condition: AwaitCondition
    public let timeoutMs: Int

    public init(condition: AwaitCondition, timeoutMs: Int = Scenario.defaultTimeoutMs) {
        self.condition = condition
        self.timeoutMs = timeoutMs
    }
}

public enum AwaitCondition: Sendable, Equatable {
    case state(pattern: String)
    case notify(count: Int)
    case result(name: String)
}

public enum DeviceEvent: Sendable, Equatable {
    case linkDrop
    case linkDropHide(ms: Int)
    case notify(count: Int)
    case readNotify(on: Bool)

    public var name: String {
        switch self {
        case .linkDrop: "linkDrop"
        case .linkDropHide: "linkDropHide"
        case .notify: "notify"
        case .readNotify: "readNotify"
        }
    }
}

extension Scenario {
    /// `expectedId`는 파일 이름(확장자 제외). `peripheral`은 이름으로 프로필을 찾는다
    public static func parse(
        _ data: Data,
        expectedId: String,
        peripheral lookup: (String) throws -> PeripheralProfile
    ) throws -> Scenario {
        let source = "scenarios/\(expectedId).json"
        let root = try JSONObject(try JSONValue.parse(data, source: source), path: source)
        try root.only(["format", "id", "summary", "status", "runsOn", "platforms", "peripheral", "steps", "expect", "diffIgnore"])

        let format = try root.int("format")
        guard format == formatVersion else {
            throw ContractError("\(source): unsupported format \(format)")
        }
        let id = try root.string("id")
        guard id == expectedId else {
            throw ContractError("\(source): id \"\(id)\" does not match file name \"\(expectedId)\"")
        }
        guard !id.isEmpty, id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }) else {
            throw ContractError("\(source): id \"\(id)\" must use only lowercase letters, digits and '-'")
        }

        let statusRaw = try root.string("status")
        guard let status = ScenarioStatus(rawValue: statusRaw) else {
            throw ContractError("\(source).status: unknown value \"\(statusRaw)\"")
        }
        let runsOn = try enumList(root, "runsOn", RunTarget.self) ?? []
        guard !runsOn.isEmpty else { throw ContractError("\(source).runsOn: must list at least one target") }
        let platforms = try enumList(root, "platforms", Platform.self) ?? Platform.allCases
        guard !platforms.isEmpty else { throw ContractError("\(source).platforms: must not be empty") }

        let peripheralName = try root.string("peripheral")
        let profile: PeripheralProfile
        do {
            profile = try lookup(peripheralName)
        } catch {
            throw ContractError("\(source).peripheral: cannot load \"\(peripheralName)\": \(error)")
        }

        var parser = StepParser(profile: profile)
        let steps = try root.array("steps").enumerated().map { i, v in
            try parser.parse(v, path: "\(source).steps[\(i)]")
        }

        let expectObj = try root.object("expect")
        var expect: [Lane: [String]] = [:]
        for key in expectObj.fields.keys.sorted() {
            guard let lane = Lane(rawValue: key) else {
                throw ContractError("\(expectObj.path): unknown lane \"\(key)\"")
            }
            expect[lane] = try expectObj.stringArray(key)
        }

        let diffIgnore = try root.optionalStringArray("diffIgnore") ?? []
        for (i, entry) in diffIgnore.enumerated() {
            let lane = entry.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
            guard entry.contains("|"), let lane, Lane(rawValue: lane) != nil else {
                throw ContractError("\(source).diffIgnore[\(i)]: expected \"<lane>|<pattern>\", got \"\(entry)\"")
            }
        }

        return Scenario(
            id: id,
            summary: try root.string("summary"),
            status: status,
            runsOn: runsOn,
            platforms: platforms,
            peripheral: profile,
            steps: steps,
            expect: expect,
            diffIgnore: diffIgnore
        )
    }

    private static func enumList<E: RawRepresentable<String>>(_ o: JSONObject, _ key: String, _: E.Type) throws -> [E]? {
        guard let raw = try o.optionalStringArray(key) else { return nil }
        return try raw.map { value in
            guard let e = E(rawValue: value) else {
                throw ContractError("\(o.path).\(key): unknown value \"\(value)\"")
            }
            return e
        }
    }
}

/// 단계 목록을 순서대로 읽는다. async 이름은 앞에서 선언된 것만 await 할 수 있다
private struct StepParser {
    let profile: PeripheralProfile
    var asyncNames: Set<String> = []

    init(profile: PeripheralProfile) {
        self.profile = profile
    }

    mutating func parse(_ value: JSONValue, path: String) throws -> Step {
        let o = try JSONObject(value, path: path)
        let kinds = ["call", "await", "device", "sleep"].filter(o.has)
        guard kinds.count == 1 else {
            let keys = o.fields.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
            throw ContractError("\(path): unknown step (need exactly one of call/await/device/sleep, got keys \(keys))")
        }
        switch kinds[0] {
        case "call": return .call(try parseCall(o))
        case "await": return .wait(try parseAwait(o))
        case "device": return .device(try parseDevice(o))
        default:
            try o.only(["sleep"])
            let ms = try o.int("sleep")
            guard ms >= 0 else { throw ContractError("\(path).sleep: must be >= 0") }
            return .sleep(ms: ms)
        }
    }

    private mutating func parseCall(_ o: JSONObject) throws -> CallStep {
        let common: Set<String> = ["call", "async", "name", "timeoutMs"]
        let name = try o.string("call")
        let action: CallAction
        switch name {
        case "connect":
            try o.only(common.union(["autoReconnect"]))
            action = .connect(autoReconnect: try o.optionalBool("autoReconnect") ?? false)
        case "disconnect":
            try o.only(common)
            action = .disconnect
        case "read", "subscribe", "unsubscribe":
            try o.only(common.union(["char"]))
            let c = try characteristic(o)
            action = name == "read" ? .read(c) : name == "subscribe" ? .subscribe(c) : .unsubscribe(c)
        case "write":
            try o.only(common.union(["char", "text", "hex", "mode"]))
            let c = try characteristic(o)
            let bytes: [UInt8]
            switch (try o.optionalString("text"), try o.optionalString("hex")) {
            case (let text?, nil): bytes = Array(text.utf8)
            case (nil, let hex?): bytes = try parseHex(hex, path: "\(o.path).hex")
            default: throw ContractError("\(o.path): write needs exactly one of \"text\" or \"hex\"")
            }
            let mode = try o.optionalString("mode") ?? "withResponse"
            guard mode == "withResponse" || mode == "withoutResponse" else {
                throw ContractError("\(o.path).mode: unknown value \"\(mode)\"")
            }
            action = .write(c, bytes: bytes, withResponse: mode == "withResponse")
        default:
            throw ContractError("\(o.path).call: unknown call \"\(name)\"")
        }

        let isAsync = try o.optionalBool("async") ?? false
        let asyncName = try o.optionalString("name")
        if isAsync {
            guard let asyncName else { throw ContractError("\(o.path): \"async\": true requires \"name\"") }
            guard asyncNames.insert(asyncName).inserted else {
                throw ContractError("\(o.path).name: duplicate async name \"\(asyncName)\"")
            }
        } else if asyncName != nil {
            throw ContractError("\(o.path).name: only allowed with \"async\": true")
        }
        return CallStep(action: action, asyncName: isAsync ? asyncName : nil, timeoutMs: try timeout(o))
    }

    private func parseAwait(_ o: JSONObject) throws -> AwaitStep {
        let kind = try o.string("await")
        let condition: AwaitCondition
        switch kind {
        case "state":
            try o.only(["await", "is", "timeoutMs"])
            condition = .state(pattern: try o.string("is"))
        case "notify":
            try o.only(["await", "count", "timeoutMs"])
            let count = try o.int("count")
            guard count >= 1 else { throw ContractError("\(o.path).count: must be >= 1") }
            condition = .notify(count: count)
        case "result":
            try o.only(["await", "name", "timeoutMs"])
            let name = try o.string("name")
            guard asyncNames.contains(name) else {
                throw ContractError("\(o.path).name: no earlier async call named \"\(name)\"")
            }
            condition = .result(name: name)
        default:
            throw ContractError("\(o.path).await: unknown condition \"\(kind)\"")
        }
        return AwaitStep(condition: condition, timeoutMs: try timeout(o))
    }

    private func parseDevice(_ o: JSONObject) throws -> DeviceEvent {
        let kind = try o.string("device")
        switch kind {
        case "linkDrop":
            try o.only(["device"])
            return .linkDrop
        case "linkDropHide":
            try o.only(["device", "ms"])
            let ms = try o.int("ms")
            guard ms > 0 else { throw ContractError("\(o.path).ms: must be > 0") }
            return .linkDropHide(ms: ms)
        case "notify":
            try o.only(["device", "count"])
            let count = try o.int("count")
            guard count >= 1 else { throw ContractError("\(o.path).count: must be >= 1") }
            return .notify(count: count)
        case "readNotify":
            try o.only(["device", "on"])
            return .readNotify(on: try o.bool("on"))
        default:
            throw ContractError("\(o.path).device: unknown device event \"\(kind)\"")
        }
    }

    private func characteristic(_ o: JSONObject) throws -> Characteristic {
        let symbol = try o.string("char")
        guard let c = profile.characteristics[symbol] else {
            throw ContractError("\(o.path).char: unknown symbol \"\(symbol)\" in peripheral \"\(profile.name)\"")
        }
        guard !c.runnerOnly else {
            throw ContractError("\(o.path).char: \"\(symbol)\" is runnerOnly")
        }
        return c
    }

    private func timeout(_ o: JSONObject) throws -> Int {
        let ms = try o.optionalInt("timeoutMs") ?? Scenario.defaultTimeoutMs
        guard ms > 0 else { throw ContractError("\(o.path).timeoutMs: must be > 0") }
        return ms
    }

    private func parseHex(_ hex: String, path: String) throws -> [UInt8] {
        let digits = Array(hex.utf8)
        // UInt8(_:radix:)는 "+f" 같은 부호를 받아 주므로 글자를 먼저 거른다
        guard digits.count % 2 == 0, digits.allSatisfy({ Character(Unicode.Scalar($0)).isHexDigit }) else {
            throw ContractError("\(path): invalid hex \"\(hex)\"")
        }
        return stride(from: 0, to: digits.count, by: 2).map { i in
            UInt8(String(decoding: digits[i..<i + 2], as: UTF8.self), radix: 16)!
        }
    }
}
