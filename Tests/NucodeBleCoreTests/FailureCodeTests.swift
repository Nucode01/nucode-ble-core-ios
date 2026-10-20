import BleContract
import Foundation
import XCTest
@testable import NucodeBleCore

final class FailureCodeTests: XCTestCase {
    private struct Entry {
        let code: String
        let category: String
        let retryability: String
        let platforms: [String]
    }

    private func entries() throws -> [Entry] {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: packageRoot)
        let data = try Data(contentsOf: dir.url.appendingPathComponent("failure-codes.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let codes = try XCTUnwrap(root["codes"] as? [[String: Any]])
        return try codes.map { item in
            Entry(
                code: try XCTUnwrap(item["code"] as? String),
                category: try XCTUnwrap(item["category"] as? String),
                retryability: try XCTUnwrap(item["retryability"] as? String),
                platforms: try XCTUnwrap(item["platforms"] as? [String])
            )
        }
    }

    /// Tests/NucodeBleCoreTests/<파일> 에서 세 단계 위가 패키지 루트
    private var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testEveryIosCodeIsAPublicConstantWithSameCategoryAndRetryability() throws {
        let byValue = Dictionary(uniqueKeysWithValues: FailureCode.all.map { ($0.value, $0) })
        for entry in try entries() where entry.platforms.contains("ios") {
            let constant = try XCTUnwrap(byValue[entry.code], "iOS 코드 \(entry.code) 의 상수가 없다")
            XCTAssertEqual(constant.category.value, entry.category, entry.code)
            XCTAssertEqual(constant.retryability.rawValue, entry.retryability, entry.code)
        }
    }

    func testNoConstantForAndroidOnlyOrUnknownCodes() throws {
        let iosCodes = Set(try entries().filter { $0.platforms.contains("ios") }.map(\.code))
        for constant in FailureCode.all {
            XCTAssertTrue(iosCodes.contains(constant.value), "\(constant.value) 은 iOS 가 내는 코드가 아니다")
        }
        XCTAssertEqual(Set(FailureCode.all.map(\.value)).count, FailureCode.all.count, "중복 상수")
        for entry in try entries() where !entry.platforms.contains("ios") {
            XCTAssertFalse(FailureCode.all.contains { $0.value == entry.code }, entry.code)
        }
    }

    func testBLEFailureDefaultsRetryabilityFromCode() {
        let failure = BLEFailure(code: .operationTimeout, message: "x")
        XCTAssertEqual(failure.retryability, .newConnectionMayHelp)
        XCTAssertEqual(failure.category, .operation)
    }

    func testBLEUUIDNormalizesToLowercase128Bit() throws {
        let short = try XCTUnwrap(BLEUUID(string: "180F"))
        XCTAssertEqual(short.string, "0000180f-0000-1000-8000-00805f9b34fb")
        let long = try XCTUnwrap(BLEUUID(string: "6E7A0001-5C3A-4B8E-9D1F-0A1B2C3D4E5F"))
        XCTAssertEqual(long.string, "6e7a0001-5c3a-4b8e-9d1f-0a1b2c3d4e5f")
        XCTAssertNil(BLEUUID(string: "xyz"))
    }
}
