import Foundation

/// 루트 저장소의 `contract/` 폴더
public struct ContractDirectory: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// 환경 변수 `BLE_CONTRACT_DIR`, 없으면 `<패키지 루트>/../contract`
    public static func locate(
        packageRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ContractDirectory {
        if let dir = environment["BLE_CONTRACT_DIR"], !dir.isEmpty {
            return ContractDirectory(url: URL(fileURLWithPath: dir, isDirectory: true))
        }
        return ContractDirectory(url: packageRoot.deletingLastPathComponent().appendingPathComponent("contract", isDirectory: true))
    }

    /// 계약 시험을 건너뛸지. `BLE_CONTRACT_DIR` 를 주지 않았고 `<패키지 루트>/../contract` 폴더도 없을 때만 true.
    /// `BLE_CONTRACT_DIR` 를 줬으면 폴더가 없어도 false 다. 읽을 때 실패해 잘못된 경로를 드러낸다
    public static func isAbsent(
        packageRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let dir = environment["BLE_CONTRACT_DIR"], !dir.isEmpty { return false }
        var isDirectory: ObjCBool = false
        let path = locate(packageRoot: packageRoot, environment: environment).url.path
        return !(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    public var scenariosURL: URL { url.appendingPathComponent("scenarios", isDirectory: true) }
    public var peripheralsURL: URL { url.appendingPathComponent("peripherals", isDirectory: true) }

    /// 시나리오 id 목록(파일 이름순)
    public func scenarioIds() throws -> [String] {
        try jsonNames(in: scenariosURL)
    }

    public func peripheralNames() throws -> [String] {
        try jsonNames(in: peripheralsURL)
    }

    public func loadPeripheral(named name: String) throws -> PeripheralProfile {
        try PeripheralProfile.parse(read(peripheralsURL.appendingPathComponent("\(name).json")), expectedName: name)
    }

    public func loadScenario(id: String) throws -> Scenario {
        try Scenario.parse(read(scenariosURL.appendingPathComponent("\(id).json")), expectedId: id, peripheral: loadPeripheral(named:))
    }

    public func loadMatchCases() throws -> [MatchCase] {
        try MatchCase.parseAll(read(url.appendingPathComponent("format-tests/match-cases.json")))
    }

    public func loadLoadCases() throws -> [LoadCase] {
        try LoadCase.parseAll(read(url.appendingPathComponent("format-tests/load-cases.json")))
    }

    private func read(_ file: URL) throws -> Data {
        do {
            return try Data(contentsOf: file)
        } catch {
            throw ContractError("cannot read \(file.path): \(error.localizedDescription)")
        }
    }

    private func jsonNames(in dir: URL) throws -> [String] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            throw ContractError("cannot list \(dir.path): \(error.localizedDescription)")
        }
        return files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }
}

/// `format-tests/match-cases.json`의 사례 하나
public struct MatchCase: Sendable, Equatable, CustomStringConvertible {
    public let expected: [String]
    public let actual: [String]
    public let match: Bool
    public let note: String?

    public var description: String {
        "\(expected) vs \(actual) -> \(match)" + (note.map { " (\($0))" } ?? "")
    }

    static func parseAll(_ data: Data) throws -> [MatchCase] {
        let source = "format-tests/match-cases.json"
        let root = try JSONObject(try JSONValue.parse(data, source: source), path: source)
        try root.only(["format", "summary", "cases"])
        let format = try root.int("format")
        guard format == Scenario.formatVersion else {
            throw ContractError("\(source): unsupported format \(format)")
        }
        return try root.array("cases").enumerated().map { i, v in
            let o = try JSONObject(v, path: "\(source).cases[\(i)]")
            try o.only(["expected", "actual", "match", "note"])
            return MatchCase(
                expected: try o.stringArray("expected"),
                actual: try o.stringArray("actual"),
                match: try o.bool("match"),
                note: try o.optionalString("note")
            )
        }
    }
}

/// `format-tests/load-cases.json`의 사례 하나. 시나리오 사례는 `probe.json`으로 읽고 파일 이름을 "x"로,
/// 기기 정의 사례는 파일 이름을 "p"로 준다. 실제 파일과 같은 검증 경로(`Scenario.parse`·`PeripheralProfile.parse`)를 탄다
public struct LoadCase: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case scenario, peripheral
    }

    public let kind: Kind
    public let note: String
    public let valid: Bool
    let body: Data

    public var description: String { "\(kind.rawValue): \(note)" }

    /// 받아들였으면 nil, 거부했으면 그 오류
    public func attempt(probe: PeripheralProfile) -> ContractError? {
        do {
            switch kind {
            case .scenario:
                _ = try Scenario.parse(body, expectedId: "x") { name in
                    guard name == probe.name else { throw ContractError("no peripheral \(name)") }
                    return probe
                }
            case .peripheral:
                _ = try PeripheralProfile.parse(body, expectedName: "p")
            }
            return nil
        } catch let error as ContractError {
            return error
        } catch {
            return ContractError("\(error)")
        }
    }

    static func parseAll(_ data: Data) throws -> [LoadCase] {
        let source = "format-tests/load-cases.json"
        let root = try JSONObject(try JSONValue.parse(data, source: source), path: source)
        try root.only(["format", "summary", "scenarioCases", "peripheralCases"])
        let format = try root.int("format")
        guard format == Scenario.formatVersion else {
            throw ContractError("\(source): unsupported format \(format)")
        }
        var cases: [LoadCase] = []
        for (key, kind) in [("scenarioCases", Kind.scenario), ("peripheralCases", Kind.peripheral)] {
            guard root.has(key) else { continue }
            for (i, v) in try root.array(key).enumerated() {
                let o = try JSONObject(v, path: "\(source).\(key)[\(i)]")
                try o.only(["note", "valid", kind.rawValue])
                guard let raw = o.fields[kind.rawValue] else {
                    throw ContractError("\(o.path): missing required key \"\(kind.rawValue)\"")
                }
                cases.append(LoadCase(
                    kind: kind,
                    note: try o.string("note"),
                    valid: try o.bool("valid"),
                    body: try raw.serialized()
                ))
            }
        }
        return cases
    }
}
