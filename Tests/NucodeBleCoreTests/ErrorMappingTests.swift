import CoreBluetooth
import XCTest
@testable import NucodeBleCore

/// CANDIDATE-8: CBError·CBATTError → BLEFailure. CoreBluetooth 를 만들지 않고 값으로 시험한다.
final class ErrorMappingTests: XCTestCase {
    private func cbError(_ code: Int) -> PortError {
        PortError(domain: "CBErrorDomain", code: code, message: "cb \(code)")
    }

    private func attError(_ code: Int) -> PortError {
        PortError(domain: "CBATTErrorDomain", code: code, message: "att \(code)")
    }

    func testPlainLinkErrorIsLinkFailedWithOriginalInPlatformDetail() {
        let failure = PlatformErrorMapping.linkFailure(cbError(6), fallback: "x")
        XCTAssertEqual(failure.code, .linkFailed)
        XCTAssertEqual(failure.retryability, FailureCode.linkFailed.retryability)
        XCTAssertEqual(failure.platformDetail?.ios?.domain, "CBErrorDomain")
        XCTAssertEqual(failure.platformDetail?.ios?.code, 6)
        XCTAssertNil(failure.platformDetail?.ios?.symbolicName)
    }

    func testLinkFailureWithoutErrorUsesFallbackMessage() {
        let failure = PlatformErrorMapping.linkFailure(nil, fallback: "링크가 끊겼다")
        XCTAssertEqual(failure.code, .linkFailed)
        XCTAssertEqual(failure.message, "링크가 끊겼다")
        XCTAssertNil(failure.platformDetail)
    }

    func testPeerRemovedPairingInformationCarriesSymbolicNameAndAfterEnvironmentChange() {
        let failure = PlatformErrorMapping.linkFailure(cbError(14), fallback: "x")
        XCTAssertEqual(failure.code, .linkFailed)
        XCTAssertEqual(failure.retryability, .afterEnvironmentChange)
        XCTAssertEqual(failure.platformDetail?.ios?.symbolicName, "PEER_REMOVED_PAIRING_INFORMATION")
        XCTAssertEqual(failure.platformDetail?.ios?.code, 14)
    }

    func testInsufficientAttErrorsAreGattStatusFailedWithSymbolicName() {
        let expected: [(Int, String)] = [
            (5, "GATT_INSUFFICIENT_AUTHENTICATION"),
            (8, "GATT_INSUFFICIENT_AUTHORIZATION"),
            (15, "GATT_INSUFFICIENT_ENCRYPTION"),
        ]
        for (code, name) in expected {
            let failure = PlatformErrorMapping.gattFailure(attError(code), operation: "read")
            XCTAssertEqual(failure.code, .gattStatusFailed, name)
            XCTAssertEqual(failure.retryability, .afterEnvironmentChange, name)
            XCTAssertEqual(failure.platformDetail?.ios?.symbolicName, name)
            XCTAssertEqual(failure.platformDetail?.ios?.domain, "CBATTErrorDomain")
            XCTAssertEqual(failure.platformDetail?.ios?.code, code)
        }
    }

    func testOtherAttErrorKeepsDefaultRetryabilityAndNoSymbolicName() {
        let failure = PlatformErrorMapping.gattFailure(attError(3), operation: "write")
        XCTAssertEqual(failure.code, .gattStatusFailed)
        XCTAssertEqual(failure.retryability, FailureCode.gattStatusFailed.retryability)
        XCTAssertNil(failure.platformDetail?.ios?.symbolicName)
    }

    func testNonAttDomainWithInsufficientCodeIsNotMappedToSymbolicName() {
        let failure = PlatformErrorMapping.gattFailure(cbError(5), operation: "read")
        XCTAssertNil(failure.platformDetail?.ios?.symbolicName)
    }

    func testPortErrorFromNSErrorKeepsDomainCodeAndMessage() {
        let ns = NSError(domain: "CBATTErrorDomain", code: 15, userInfo: [NSLocalizedDescriptionKey: "enc"])
        let port = PortErrorConversion.portError(ns)
        XCTAssertEqual(port, PortError(domain: "CBATTErrorDomain", code: 15, message: "enc"))
    }

    /// CANDIDATE-23: 같은 식별자의 두 번째 생성은 거절, 식별자 없는 client 는 제한 없음(trap 자체는 시험하지 않는다)
    func testRestoreIdentifierClaimIsRefusedTheSecondTime() {
        let identifier = "kr.co.nucode.test.\(UUID().uuidString)"
        XCTAssertTrue(RestoreIdentifierGuard.claim(identifier))
        XCTAssertFalse(RestoreIdentifierGuard.claim(identifier))
        RestoreIdentifierGuard.claimOrTrap(nil)
        RestoreIdentifierGuard.claimOrTrap(nil)
    }

    /// 공개 factory 는 생성 때 restoreIdentifier 를 점유한다(`start()` 없이)
    func testFactoryClaimsRestoreIdentifier() {
        let identifier = "kr.co.nucode.test.\(UUID().uuidString)"
        _ = BLEClientFactory.make(options: BLEOptions(restoreIdentifier: identifier))
        XCTAssertFalse(RestoreIdentifierGuard.claim(identifier))
    }

    /// 식별자 없는 factory 생성은 여러 번 해도 된다
    func testFactoryWithoutIdentifierCanBeMadeTwice() {
        _ = BLEClientFactory.make()
        _ = BLEClientFactory.make()
    }
}

/// CANDIDATE-30: `CBCharacteristicProperties` → `CharacteristicProperty`(요청서 §3.2 표). 값으로 시험한다
final class CharacteristicPropertyMappingTests: XCTestCase {
    func testEachKeptBitMapsToOneProperty() {
        let cases: [(CBCharacteristicProperties, CharacteristicProperty)] = [
            (.read, .read),
            (.write, .writeWithResponse),
            (.writeWithoutResponse, .writeWithoutResponse),
            (.notify, .notify),
            (.indicate, .indicate),
        ]
        for (bit, property) in cases {
            XCTAssertEqual(CharacteristicPropertyConversion.properties(bit), [property], "\(bit)")
        }
        XCTAssertEqual(Set(cases.map(\.1)), Set(CharacteristicProperty.allCases))
    }

    func testOtherBitsAreDropped() {
        let dropped: CBCharacteristicProperties = [
            .broadcast, .authenticatedSignedWrites, .extendedProperties, .notifyEncryptionRequired, .indicateEncryptionRequired,
        ]
        XCTAssertEqual(CharacteristicPropertyConversion.properties(dropped), [])
        XCTAssertEqual(CharacteristicPropertyConversion.properties([]), [])
        XCTAssertEqual(CharacteristicPropertyConversion.properties(dropped.union([.read, .notify])), [.read, .notify])
    }
}
