import Foundation
import XCTest

/// 의존 규칙을 소스로 확인한다: Domain ← Application ← Infrastructure, 라이브러리 이름은 Infrastructure 에만
final class ArchitectureTests: XCTestCase {
    /// ManualTestKit 폴더
    let kit = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func testDomainImportsOnlyFoundation() throws {
        try assertImports(of: "ManualTestDomain", allowed: ["Foundation"])
    }

    func testApplicationImportsOnlyFoundationAndDomain() throws {
        try assertImports(of: "ManualTestApplication", allowed: ["Foundation", "ManualTestDomain"])
    }

    func testLibraryNameAppearsOnlyInInfrastructure() throws {
        let roots = [kit.appending(path: "Sources"), kit.deletingLastPathComponent().appending(path: "App")]
        let files = try roots.flatMap(swiftFiles)
        XCTAssertFalse(files.isEmpty)
        XCTAssertTrue(files.contains { $0.path.contains("/App/") }, "App 소스도 검사한다")
        for file in files where !file.path.contains("/Sources/ManualTestInfrastructure/") {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("NucodeBleCore"), "\(file.lastPathComponent) 가 라이브러리를 안다")
        }
    }

    private func assertImports(of target: String, allowed: Set<String>) throws {
        let files = try swiftFiles(kit.appending(path: "Sources/\(target)"))
        XCTAssertFalse(files.isEmpty)
        for file in files {
            for module in try imports(file) {
                XCTAssertTrue(allowed.contains(module), "\(target)/\(file.lastPathComponent) imports \(module)")
            }
        }
    }

    /// `import X`, `@testable import X`, `import struct X.Y` 모두 모듈 이름만 뽑는다
    private func imports(_ file: URL) throws -> [String] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").compactMap { line in
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
            guard let index = words.firstIndex(of: "import"), words[..<index].allSatisfy({ $0.hasPrefix("@") }) else { return nil }
            let rest = words[(index + 1)...].drop { ["struct", "class", "enum", "protocol", "func", "var", "let", "typealias"].contains($0) }
            return rest.first.map { String($0.split(separator: ".")[0]) }
        }
    }

    private func swiftFiles(_ root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
