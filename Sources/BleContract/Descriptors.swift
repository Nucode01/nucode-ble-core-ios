import Foundation

// descriptor 형식(CANDIDATE-32): 기기 정의 `descriptors`, `readDescriptor`·`writeDescriptor` 호출, 백엔드 입구.
// Scenario.swift·ScenarioEngine.swift 는 baseline 400줄 초과라 따로 둔다

/// 기기 정의 characteristic 의 `descriptors` 항목
public struct DescriptorDefinition: Sendable, Equatable {
    public static let cccdUUID = "00002902-0000-1000-8000-00805f9b34fb"
    static let knownProperties: Set<String> = ["read", "write"]

    public let name: String
    public let uuid: String
    public let properties: [String]
    /// 연결을 시작할 때의 값. CCCD 와 값을 적지 않은 descriptor 는 nil
    public let value: [UInt8]?

    /// 이름 → 정의. JSON 트리가 키 순서를 잃어 탐색 순서는 담지 않는다
    static func parseAll(_ objs: JSONObject) throws -> [String: DescriptorDefinition] {
        var result: [String: DescriptorDefinition] = [:]
        var uuids: Set<String> = []
        for name in objs.fields.keys.sorted() {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else {
                throw ContractError("\(objs.path): descriptor name \"\(name)\" must use only lowercase letters and digits")
            }
            let d = try objs.object(name)
            try d.only(["uuid", "properties", "value"])
            let uuid = try d.string("uuid")
            guard UUID(uuidString: uuid) != nil else {
                throw ContractError("\(d.path).uuid: not a UUID: \"\(uuid)\"")
            }
            guard uuids.insert(uuid.lowercased()).inserted else {
                throw ContractError("\(d.path).uuid: \"\(uuid)\" repeats in this characteristic")
            }
            let properties = try d.stringArray("properties")
            guard !properties.isEmpty else { throw ContractError("\(d.path).properties: must not be empty") }
            if let bad = properties.first(where: { !knownProperties.contains($0) }) {
                throw ContractError("\(d.path).properties: unknown property \"\(bad)\"")
            }
            guard Set(properties).count == properties.count else {
                throw ContractError("\(d.path).properties: duplicate property")
            }
            var value: [UInt8]?
            if d.has("value") {
                guard uuid.lowercased() != cccdUUID else {
                    throw ContractError("\(d.path).value: not allowed on CCCD (0x2902)")
                }
                value = try parseHex(try d.string("value"), path: "\(d.path).value")
            }
            result[name] = DescriptorDefinition(name: name, uuid: uuid, properties: properties, value: value)
        }
        return result
    }
}

/// 시나리오의 `desc`(`<characteristic 기호>/<이름>`)를 푼 것
public struct DescriptorTarget: Sendable, Equatable {
    public let characteristic: Characteristic
    public let descriptor: DescriptorDefinition

    /// `probe.control/cud`
    public var symbol: String { characteristic.symbol + "/" + descriptor.name }
}

/// 백엔드의 descriptor 호출. `ScenarioBackend` 가 상속한다
public protocol DescriptorBackend: Sendable {
    /// 읽은 값은 `CallOutcome.descriptorRead`로 돌려준다
    func readDescriptor(_ target: DescriptorTarget) async throws -> CallOutcome
    /// 항상 응답 있는 쓰기, 나누지 않는다
    func writeDescriptor(_ target: DescriptorTarget, bytes: [UInt8]) async throws -> CallOutcome
}

extension CallOutcome {
    /// `readDescriptor <desc> ok <대문자 16진수>`. 값이 비면 `ok`로 끝난다
    public static func descriptorRead(_ bytes: [UInt8]) -> CallOutcome {
        bytes.isEmpty ? .ok : .okWith(bytes.map { String(format: "%02X", $0) }.joined())
    }
}

extension Scenario {
    /// descriptor 호출이 있거나 `expect`에 `descriptors` 레인이 있다
    public var usesDescriptors: Bool {
        expect[.descriptors] != nil || steps.contains { step in
            guard case .call(let call) = step else { return false }
            switch call.action {
            case .readDescriptor, .writeDescriptor: return true
            default: return false
            }
        }
    }

    /// iOS 코어에 descriptor API 가 생기기 전(CANDIDATE-32)에는 iOS 에서 통과할 수 없는 draft.
    /// sim·device 시험이 이 시나리오의 실패를 known issue 로 둔다. 구현 뒤 통과하면 시험이 알린다
    public var awaitsIosDescriptorSupport: Bool {
        status == .draft && usesDescriptors
    }
}

extension StepParser {
    /// `readDescriptor`·`writeDescriptor`. `common`은 모든 호출이 받는 키(`async`·`name`·`timeoutMs`)
    func descriptorCall(_ name: String, _ o: JSONObject, common: Set<String>) throws -> CallAction {
        let isWrite = name == "writeDescriptor"
        try o.only(common.union(isWrite ? ["desc", "text", "hex"] : ["desc"]))
        let target = try descriptor(o, needs: isWrite ? "write" : "read")
        guard isWrite else { return .readDescriptor(target) }
        let given = ["text", "hex"].filter(o.has)
        guard given.count == 1 else {
            throw ContractError("\(o.path): writeDescriptor needs exactly one of \"text\" or \"hex\"")
        }
        let bytes = given[0] == "text"
            ? Array(try o.string("text").utf8)
            : try parseHex(try o.string("hex"), path: "\(o.path).hex")
        return .writeDescriptor(target, bytes: bytes)
    }

    /// `runnerOnly` characteristic 의 descriptor 도 받는다(`runnerOnly`는 characteristic 값 호출만 막는다)
    private func descriptor(_ o: JSONObject, needs property: String) throws -> DescriptorTarget {
        let ref = try o.string("desc")
        let parts = ref.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw ContractError("\(o.path).desc: expected \"<char>/<name>\", got \"\(ref)\"")
        }
        guard let c = profile.characteristics[parts[0]] else {
            throw ContractError("\(o.path).desc: unknown symbol \"\(parts[0])\" in peripheral \"\(profile.name)\"")
        }
        guard let d = c.descriptors[parts[1]] else {
            throw ContractError("\(o.path).desc: \"\(parts[0])\" has no descriptor \"\(parts[1])\"")
        }
        guard d.properties.contains(property) else {
            throw ContractError("\(o.path).desc: \"\(ref)\" has no \(property) property")
        }
        return DescriptorTarget(characteristic: c, descriptor: d)
    }
}
