@testable import BLEDemo
import Foundation
import NucodeBleCore
import XCTest

/// 테스트용 `BLESession`. 상태 스트림은 현재 값을 먼저 보내고 이후 변화를 보낸다
final class FakeSession: BLESession, @unchecked Sendable {
    enum ConnectBehavior { case becomeReady, stayConnecting }

    let peripheralID = PeripheralID(rawValue: "FAKE-0001")
    private let lock = NSLock()
    private var current: ConnectionState = .disconnected(reason: .initial)
    private var stateContinuations: [AsyncStream<ConnectionState>.Continuation] = []
    private var notificationContinuations: [CharacteristicRef: [AsyncStream<Data>.Continuation]] = [:]

    var connectBehavior: ConnectBehavior = .becomeReady
    var writeError: BLEError?

    private(set) var connectOptions: [ConnectOptions] = []
    private(set) var disconnectCount = 0
    private(set) var subscribed: [CharacteristicRef] = []
    private(set) var writes: [(ref: CharacteristicRef, value: Data, options: WriteOptions)] = []

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var connectionStates: AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream<ConnectionState>.makeStream()
        locked {
            continuation.yield(current)
            stateContinuations.append(continuation)
        }
        return stream
    }

    var services: AsyncStream<[GATTService]> {
        AsyncStream { $0.yield([]) }
    }

    var activeSubscriptions: AsyncStream<Set<CharacteristicRef>> {
        AsyncStream { $0.yield([]) }
    }

    func push(_ state: ConnectionState) {
        let targets = locked {
            current = state
            return stateContinuations
        }
        targets.forEach { $0.yield(state) }
    }

    func pushNotification(_ data: Data, for ref: CharacteristicRef) {
        let targets = locked { notificationContinuations[ref] ?? [] }
        targets.forEach { $0.yield(data) }
    }

    func connect(options: ConnectOptions) async throws {
        let behavior = locked {
            connectOptions.append(options)
            return connectBehavior
        }
        push(.connecting)
        if behavior == .becomeReady {
            push(.ready)
        }
    }

    func disconnect() async {
        locked { disconnectCount += 1 }
        push(.disconnected(reason: .requested))
    }

    func read(_ characteristic: CharacteristicRef) async throws -> Data { Data() }

    func write(_ characteristic: CharacteristicRef, value: Data, options: WriteOptions) async throws -> WriteReceipt {
        let error = locked {
            writes.append((characteristic, value, options))
            return writeError
        }
        if let error { throw error }
        return WriteReceipt(bytesCompleted: value.count, chunksCompleted: 1, delivery: .remoteAcknowledged)
    }

    func subscribe(_ characteristic: CharacteristicRef) async throws {
        locked { subscribed.append(characteristic) }
    }

    func notifications(for characteristic: CharacteristicRef) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        locked { notificationContinuations[characteristic, default: []].append(continuation) }
        return stream
    }

    func unsubscribe(_ characteristic: CharacteristicRef) async throws {}
}

@MainActor
final class TerminalControllerTests: XCTestCase {
    private let target = DeviceTarget(id: PeripheralID(rawValue: "FAKE-0001"), name: "Fake")

    /// 조건이 참이 될 때까지 최대 2초 기다린다
    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testConnectSuccessSubscribesAndRemembers() async {
        let session = FakeSession()
        var connected: [DeviceTarget] = []
        let controller = TerminalController(target: target, session: session) { connected.append($0) }
        controller.activate()
        await controller.connect()
        await eventually { controller.lines.contains { $0.kind == .system && $0.text == "준비됨" } }

        guard case .ready = controller.state else { return XCTFail("state: \(controller.state)") }
        XCTAssertEqual(session.subscribed, [NUS.tx])
        XCTAssertEqual(connected, [target])
        XCTAssertTrue(controller.lines.contains { $0.kind == .system && $0.text == "준비됨" })
        XCTAssertFalse(controller.isBusy)
    }

    func testConnectTimeoutDisconnectsAndShowsError() async {
        let session = FakeSession()
        session.connectBehavior = .stayConnecting
        let controller = TerminalController(target: target, session: session, connectTimeout: .milliseconds(100))
        controller.activate()
        await controller.connect()

        XCTAssertEqual(session.disconnectCount, 1)
        XCTAssertTrue(controller.lines.contains { $0.kind == .error && $0.text.contains("기기를 찾지 못했습니다") })
        XCTAssertFalse(controller.isBusy)
        XCTAssertTrue(session.subscribed.isEmpty)
    }

    func testSendFailureShowsUserMessage() async {
        let session = FakeSession()
        let error = BLEError(failure: BLEFailure(code: .notReady, message: "x"))
        session.writeError = error
        let controller = TerminalController(target: target, session: session)
        await controller.send("hi")

        XCTAssertEqual(controller.lines.filter { $0.kind == .error }.map(\.text), [userMessage(for: error)])
        XCTAssertFalse(controller.lines.contains { $0.kind == .sent })
    }

    func testSendAppendsNewlineAndShowsText() async {
        let session = FakeSession()
        let controller = TerminalController(target: target, session: session)
        controller.appendNewline = true
        await controller.send("hi")

        XCTAssertEqual(session.writes.count, 1)
        XCTAssertEqual(session.writes.first?.ref, NUS.rx)
        XCTAssertEqual(session.writes.first?.value, Data("hi\r\n".utf8))
        XCTAssertEqual(controller.lines.filter { $0.kind == .sent }.map(\.text), ["hi"])
    }

    func testReceivedNotificationsAreDisplayed() async {
        let session = FakeSession()
        let controller = TerminalController(target: target, session: session)
        controller.activate()
        session.pushNotification(Data([0xff, 0x00]), for: NUS.tx)
        session.pushNotification(Data("IT|STATUS\r\n".utf8), for: NUS.tx)
        await eventually { controller.lines.filter { $0.kind == .received }.count >= 2 }

        XCTAssertEqual(controller.lines.filter { $0.kind == .received }.map(\.text), ["hex ff 00", "IT|STATUS"])
    }

    func testLinesAreCappedAt500() {
        let controller = TerminalController(target: target, session: FakeSession())
        for index in 1...600 {
            controller.append(.system, "line \(index)")
        }

        XCTAssertEqual(controller.lines.count, 500)
        XCTAssertEqual(controller.lines.first?.text, "line 101")
    }
}
