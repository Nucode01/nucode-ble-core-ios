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
    /// sim 전용. 가짜 플랫폼의 어댑터를 바꾼다
    case adapter(AdapterValue)
    /// 앞선 async 호출의 호출자를 취소한다(전달 계획 §5-3). 끝나지 않았으면 `result`에 `<호출> cancelled`를 남긴다
    case cancel(name: String)
}

/// `adapter` 레인·`adapter` 단계의 값
public enum AdapterValue: String, Sendable, CaseIterable {
    case unknown = "Unknown"
    case ready = "Ready"
    case poweredOff = "PoweredOff"
    case resetting = "Resetting"
    case unsupported = "Unsupported"
    case unauthorizedCanRequest = "Unauthorized(true)"
    case unauthorizedDenied = "Unauthorized(false)"
}

/// write 의 나누기. 공개 API `BleChunking`
public enum WriteChunking: Sendable, Equatable {
    case automatic
    case disabled
    case fixed(bytes: Int)
}

/// `startScan` 의 `filter`. 서비스는 기기 정의 `services` 의 기호 이름이 아니라 풀어 낸 UUID 로 둔다
public struct ScanFilter: Sendable, Equatable {
    public let name: String?
    /// 기호 이름(`nus`)과 UUID. 비어 있으면 서비스 필터 없음
    public let services: [ServiceRef]

    public init(name: String? = nil, services: [ServiceRef] = []) {
        self.name = name
        self.services = services
    }

    public static let none = ScanFilter()
}

public struct ServiceRef: Sendable, Equatable {
    public let symbol: String
    public let uuid: String

    public init(symbol: String, uuid: String) {
        self.symbol = symbol
        self.uuid = uuid
    }
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
    case write(Characteristic, bytes: [UInt8], withResponse: Bool, chunking: WriteChunking = .automatic)
    case subscribe(Characteristic)
    case unsubscribe(Characteristic)
    case readDescriptor(DescriptorTarget)
    case writeDescriptor(DescriptorTarget, bytes: [UInt8])
    case startScan(ScanFilter)
    case stopScan
    case snapshot
    case close

    /// `result` 레인 항목의 앞부분. `read probe.value`
    public var label: String {
        switch self {
        case .connect: "connect"
        case .disconnect: "disconnect"
        case .read(let c): "read \(c.symbol)"
        case .write(let c, _, _, _): "write \(c.symbol)"
        case .subscribe(let c): "subscribe \(c.symbol)"
        case .unsubscribe(let c): "unsubscribe \(c.symbol)"
        case .readDescriptor(let d): "readDescriptor \(d.symbol)"
        case .writeDescriptor(let d, _): "writeDescriptor \(d.symbol)"
        case .startScan: "startScan"
        case .stopScan: "stopScan"
        case .snapshot: "snapshot"
        case .close: "close"
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
    /// `active`·`adapter`·`scan`·`services` 레인의 마지막 기록이 패턴과 맞는다
    case value(Lane, pattern: String)
    /// `found` 기록이 count 개 이상
    case found(count: Int)
}

public enum DeviceEvent: Sendable, Equatable {
    case linkDrop
    case linkDropHide(ms: Int)
    case notify(count: Int)
    case readNotify(on: Bool)
    case rxCheck

    public var name: String {
        switch self {
        case .linkDrop: "linkDrop"
        case .linkDropHide: "linkDropHide"
        case .notify: "notify"
        case .readNotify: "readNotify"
        case .rxCheck: "rxCheck"
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

        let expectObj = try root.object("expect")
        var expect: [Lane: [String]] = [:]
        for key in expectObj.fields.keys.sorted() {
            guard let lane = Lane(rawValue: key) else {
                throw ContractError("\(expectObj.path): unknown lane \"\(key)\"")
            }
            expect[lane] = try expectObj.stringArray(key)
        }

        // 확장 레인을 기다리는 단계는 그 레인이 expect 에 있어야 하므로 expect 를 먼저 읽는다
        var parser = StepParser(profile: profile, runsOn: runsOn, platforms: platforms, expectLanes: Set(expect.keys))
        let steps = try root.array("steps").enumerated().map { i, v in
            try parser.parse(v, path: "\(source).steps[\(i)]")
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
struct StepParser {
    let profile: PeripheralProfile
    let runsOn: [RunTarget]
    let platforms: [Platform]
    let expectLanes: Set<Lane>
    var asyncNames: Set<String> = []
    var cancelledNames: Set<String> = []

    mutating func parse(_ value: JSONValue, path: String) throws -> Step {
        let o = try JSONObject(value, path: path)
        let kinds = ["call", "await", "device", "sleep", "adapter", "cancel"].filter(o.has)
        guard kinds.count == 1 else {
            let keys = o.fields.keys.sorted().map { "\"\($0)\"" }.joined(separator: ", ")
            throw ContractError("\(path): unknown step (need exactly one of call/await/device/sleep/adapter/cancel, got keys \(keys))")
        }
        switch kinds[0] {
        case "call": return .call(try parseCall(o))
        case "await": return .wait(try parseAwait(o))
        case "device": return .device(try parseDevice(o))
        case "cancel":
            try o.only(["cancel"])
            let name = try o.string("cancel")
            guard asyncNames.contains(name) else {
                throw ContractError("\(path).cancel: no earlier async call named \"\(name)\"")
            }
            guard cancelledNames.insert(name).inserted else {
                throw ContractError("\(path).cancel: \"\(name)\" is already cancelled")
            }
            return .cancel(name: name)
        case "adapter":
            try o.only(["adapter"])
            guard !runsOn.contains(.device) else {
                throw ContractError("\(path): adapter steps are sim-only, but runsOn includes device")
            }
            let raw = try o.string("adapter")
            guard let value = AdapterValue(rawValue: raw) else {
                throw ContractError("\(path).adapter: unknown value \"\(raw)\"")
            }
            return .adapter(value)
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
            try o.only(common.union(["autoReconnect", "requestedMtu"]))
            try checkRequestedMtu(o)
            action = .connect(autoReconnect: try o.optionalBool("autoReconnect") ?? false)
        case "disconnect":
            try o.only(common)
            action = .disconnect
        case "read", "subscribe", "unsubscribe":
            try o.only(common.union(["char"]))
            let c = try characteristic(o)
            action = name == "read" ? .read(c) : name == "subscribe" ? .subscribe(c) : .unsubscribe(c)
        case "write":
            try o.only(common.union(["char", "text", "hex", "pattern", "mode", "chunking", "chunkBytes"]))
            let c = try characteristic(o)
            let given = ["text", "hex", "pattern"].filter(o.has)
            guard given.count == 1 else {
                throw ContractError("\(o.path): write needs exactly one of \"text\", \"hex\" or \"pattern\"")
            }
            let bytes: [UInt8]
            switch given[0] {
            case "text": bytes = Array(try o.string("text").utf8)
            case "hex": bytes = try parseHex(try o.string("hex"), path: "\(o.path).hex")
            default:
                let n = try o.int("pattern")
                guard n % 256 == 0, (256...65536).contains(n) else {
                    throw ContractError("\(o.path).pattern: must be a multiple of 256 from 256 to 65536, got \(n)")
                }
                bytes = (0..<n).map { UInt8($0 % 256) }
            }
            let mode = try o.optionalString("mode") ?? "withResponse"
            guard mode == "withResponse" || mode == "withoutResponse" else {
                throw ContractError("\(o.path).mode: unknown value \"\(mode)\"")
            }
            let chunkingName = try o.optionalString("chunking") ?? "automatic"
            let chunking: WriteChunking
            switch chunkingName {
            case "automatic", "disabled":
                guard !o.has("chunkBytes") else {
                    throw ContractError("\(o.path).chunkBytes: only allowed with chunking \"fixed\"")
                }
                chunking = chunkingName == "automatic" ? .automatic : .disabled
            case "fixed":
                guard o.has("chunkBytes") else {
                    throw ContractError("\(o.path): chunking \"fixed\" requires \"chunkBytes\"")
                }
                let n = try o.int("chunkBytes")
                guard n >= 1 else { throw ContractError("\(o.path).chunkBytes: must be >= 1") }
                chunking = .fixed(bytes: n)
            default:
                throw ContractError("\(o.path).chunking: unknown value \"\(chunkingName)\"")
            }
            action = .write(c, bytes: bytes, withResponse: mode == "withResponse", chunking: chunking)
        case "readDescriptor", "writeDescriptor":
            action = try descriptorCall(name, o, common: common)
        case "startScan":
            try o.only(common.union(["filter"]))
            action = .startScan(try scanFilter(o))
        case "stopScan", "snapshot", "close":
            try o.only(common)
            action = name == "stopScan" ? .stopScan : name == "snapshot" ? .snapshot : .close
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
        case "active", "adapter", "scan", "services", "adTypes", "writeLimits", "androidMtu":
            try o.only(["await", "is", "timeoutMs"])
            let lane = Lane(rawValue: kind)!
            try requireInExpect(lane, o)
            condition = .value(lane, pattern: try o.string("is"))
        case "found":
            try o.only(["await", "count", "timeoutMs"])
            try requireInExpect(.found, o)
            let count = try o.int("count")
            guard count >= 1 else { throw ContractError("\(o.path).count: must be >= 1") }
            condition = .found(count: count)
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
        case "rxCheck":
            try o.only(["device"])
            try requireInExpect(.peer, o, what: "rxCheck")
            return .rxCheck
        default:
            throw ContractError("\(o.path).device: unknown device event \"\(kind)\"")
        }
    }

    private func requireInExpect(_ lane: Lane, _ o: JSONObject, what: String? = nil) throws {
        guard !lane.isExtension || expectLanes.contains(lane) else {
            throw ContractError("\(o.path): \(what ?? "awaiting") needs lane \"\(lane.rawValue)\" in expect")
        }
    }

    private func scanFilter(_ o: JSONObject) throws -> ScanFilter {
        guard o.has("filter") else { return .none }
        let f = try o.object("filter")
        try f.only(["name", "services"])
        var refs: [ServiceRef] = []
        if f.has("services") {
            let symbols = try f.stringArray("services")
            guard !symbols.isEmpty else { throw ContractError("\(f.path).services: must not be empty") }
            for symbol in symbols {
                guard let service = profile.services[symbol] else {
                    throw ContractError("\(f.path).services: unknown service symbol \"\(symbol)\" in peripheral \"\(profile.name)\"")
                }
                refs.append(ServiceRef(symbol: symbol, uuid: service.uuid))
            }
        }
        return ScanFilter(name: try f.optionalString("name"), services: refs)
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
}
