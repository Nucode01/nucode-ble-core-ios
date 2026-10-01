import Foundation
import XCTest

/// 앱 소스 구조 규칙: `BLEClient(` 는 BLEController.swift 에만, `import CoreBluetooth` 는 없음
final class ArchitectureGrepTests: XCTestCase {
    private func appSources() throws -> [(name: String, text: String)] {
        let appDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App")
        guard let walker = FileManager.default.enumerator(at: appDir, includingPropertiesForKeys: nil) else {
            XCTFail("App 디렉터리를 열 수 없음: \(appDir.path)")
            return []
        }
        var files: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        XCTAssertFalse(files.isEmpty, "App 소스를 찾지 못함: \(appDir.path)")
        return files
    }

    func testBLEClientCreatedOnlyInBLEController() throws {
        let offenders = try appSources()
            .filter { $0.name != "BLEController.swift" && $0.text.contains("BLEClient(") }
            .map(\.name)
        XCTAssertTrue(offenders.isEmpty, "BLEClient( 가 BLEController.swift 밖에 있음: \(offenders)")
    }

    func testNoCoreBluetoothImport() throws {
        let offenders = try appSources()
            .filter { $0.text.contains("import CoreBluetooth") }
            .map(\.name)
        XCTAssertTrue(offenders.isEmpty, "import CoreBluetooth 가 있음: \(offenders)")
    }
}
