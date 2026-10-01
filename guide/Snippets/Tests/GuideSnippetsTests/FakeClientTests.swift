@testable import GuideSnippets
import NucodeBleCore
import XCTest

/// 가이드의 가짜 client 가 레시피에 적은 라이브러리 규칙을 실제로 지키는지 본다
final class FakeClientTests: XCTestCase {
    private func makeClient() -> FakeClient {
        FakeClient(session: { _ in fatalError("이 시험은 세션을 쓰지 않는다") })
    }

    /// `body` 가 `seconds` 안에 끝나지 않으면 실패한다(교착 감지)
    private func within<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); return nil }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else {
                XCTFail("\(seconds)초 안에 끝나지 않았다")
                throw CancellationError()
            }
            return value
        }
    }

    func testStateStreamGivesCurrentValueFirst() async throws {
        let client = makeClient()
        client.start()
        let first = try await within(1) { await client.adapterStates.first { _ in true } }
        XCTAssertEqual(first, .ready)
    }

    func testEventStreamDoesNotReplay() async throws {
        let client = makeClient()
        client.eventLog.send(.diagnostic(code: .cleanupFailure, message: "before"))
        let events = client.events
        client.eventLog.send(.diagnostic(code: .cleanupFailure, message: "after"))
        client.close()
        let messages = try await within(1) { () -> [String] in
            var seen: [String] = []
            for await event in events { if case .diagnostic(_, let message) = event { seen.append(message) } }
            return seen
        }
        XCTAssertEqual(messages, ["after"])
    }

    func testCloseEndsLiveSubscriptionsWithoutDeadlock() async throws {
        let client = makeClient()
        let adapter = client.adapterStates
        let events = client.events
        let scan = client.scanStates
        // 구독자가 살아 있는 채로 닫는다. 교착이면 시험이 멈추지 않고 실패하도록 다른 스레드에서 부르고 기한을 둔다
        let done = DispatchSemaphore(value: 0)
        Thread { client.close(); done.signal() }.start()
        XCTAssertEqual(done.wait(timeout: .now() + 2), .success, "close() 가 2초 안에 끝나지 않았다(교착)")
        let ended = try await within(2) { () -> Bool in
            for await _ in adapter {}
            for await _ in events {}
            for await _ in scan {}
            return true
        }
        XCTAssertTrue(ended)
    }

    func testAfterCloseCommandsFailAndStateIsFrozen() async throws {
        let client = makeClient()
        client.close()
        client.start() // 닫힌 뒤의 상태 변경은 무시된다
        XCTAssertThrowsError(try client.session(for: PeripheralID(rawValue: "x"))) { error in
            XCTAssertEqual((error as? BLEError)?.failure.code, .clientClosed)
        }
        let values = try await within(1) { () -> [AdapterState] in
            var seen: [AdapterState] = []
            for await state in client.adapterStates { seen.append(state) }
            return seen
        }
        XCTAssertEqual(values, [.unknown]) // 마지막 값 하나를 주고 끝난다
        let snapshot = await client.snapshot()
        XCTAssertEqual(snapshot.adapter, .unknown)
    }
}
