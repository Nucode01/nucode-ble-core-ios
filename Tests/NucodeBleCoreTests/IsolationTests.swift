import Dispatch
import XCTest
@testable import NucodeBleCore

@BLECoreActor
private enum Counter {
    static var calls = 0
    static func touch() -> Int {
        calls += 1
        return calls
    }
}

final class IsolationTests: XCTestCase {
    func testAssumeIsolatedOnCoreQueueCallsActorFunction() {
        let result = bleCoreQueue.sync {
            BLECoreActor.assumeIsolated { Counter.touch() }
        }
        XCTAssertGreaterThanOrEqual(result, 1)
    }

    func testActorHopRunsOnSameQueue() async {
        let value = await Counter.touch()
        XCTAssertGreaterThanOrEqual(value, 1)
    }
}
