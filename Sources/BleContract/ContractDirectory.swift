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
