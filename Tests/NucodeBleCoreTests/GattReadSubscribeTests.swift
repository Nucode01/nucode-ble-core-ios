import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// read, subscribe, 알림, 활성 구독, CBATTError 매핑 (contract/states.md §5·§9·§10)
@BLECoreActor
final class GattReadSubscribeTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private func isReady(_ session: Session) -> Bool {
        if case .ready = session.state.value { return true }
        return false
    }

    private func makeClient() throws -> (DefaultBLEClient, FakeCentral, Session) {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        return (client, central, client.runtime.registry.session(for: id))
    }

    private func makeReady(autoReconnect: Bool = false) async throws -> (DefaultBLEClient, FakeCentral, Session) {
        let (client, central, session) = try makeClient()
        _ = try await client.connect(id, options: ConnectOptions(autoReconnect: autoReconnect))
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        return (client, central, session)
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "ok"
        } catch let error as BLEError {
            return error.failure.code.value
        } catch {
            return "other"
        }
    }

    private func ref(_ central: FakeCentral, _ symbol: String) -> CharacteristicRef {
        central.peripheral.characteristicRef(symbol)
    }

    private func collect(_ stream: AsyncStream<Data>) -> Collector {
        Collector(stream)
    }

    // MARK: 진입 검사

    /// 어댑터가 Unknown 이면 GATT 명령도 connect 와 같이 판정을 기다린다(states.md §6). `start()` 전에는 manager 가 없어 Unknown 이다
    func testEntryWaitsForUnknownAdapter() async throws {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        let session = client.runtime.registry.session(for: id)
        let value = ref(central, "probe.value")

        // 풀리지 않으면 2000ms 뒤 ADAPTER_UNAVAILABLE
        var result = await code { _ = try await session.read(value) }
        XCTAssertEqual(result, "ADAPTER_UNAVAILABLE", "Unknown 이 풀리지 않음")

        // 대기 중 호출자 취소: 접수 전이라 아무 일도 없고 취소로 끝난다
        let cancelled = Task { @BLECoreActor in await self.code { _ = try await session.read(value) } }
        await Support.sleep(realMilliseconds: 20)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertEqual(cancelledResult, "other", "취소는 CancellationError")

        // 대기 중 Ready 로 풀리면 세션 검사로 넘어가 NOT_READY(연결 전)
        let waiting = Task { @BLECoreActor in await self.code { try await session.subscribe(value) } }
        await Support.sleep(realMilliseconds: 20)
        client.start()
        result = await waiting.value
        XCTAssertEqual(result, "NOT_READY", "Unknown → Ready 뒤 세션 검사")
        XCTAssertTrue(session.snapshot().subscriptions.isEmpty)
        client.close()
    }

    func testEntryChecks() async throws {
        let (client, central, session) = try makeClient()
        let value = ref(central, "probe.value")
        var result = await code { _ = try await session.read(value) }
        XCTAssertEqual(result, "NOT_READY", "연결 전: 세션이 Ready 가 아니다(states.md §5 진입 검사 3)")
        _ = try await client.connect(id, options: ConnectOptions())
        result = await code { try await session.subscribe(value) }
        XCTAssertEqual(result, "NOT_READY")
        _ = await waitUntil { isReady(session) }
        let unknown = CharacteristicRef(service: value.service, uuid: BLEUUID(string: "abcd")!, instanceIndex: 0)
        result = await code { _ = try await session.read(unknown) }
        XCTAssertEqual(result, "CHARACTERISTIC_NOT_FOUND")
        client.close()
        result = await code { _ = try await session.read(value) }
        XCTAssertEqual(result, "CLIENT_CLOSED")
        result = await code { try await session.unsubscribe(value) }
        XCTAssertEqual(result, "CLIENT_CLOSED")
    }

    // MARK: read

    func testReadReturnsValue() async throws {
        let (client, central, session) = try await makeReady()
        let data = try await session.read(ref(central, "probe.value"))
        XCTAssertEqual(data.count, 4)
        client.close()
    }

    func testReadOfUnreadableCharacteristicFailsWithStatus() async throws {
        let (client, central, session) = try await makeReady()
        let result = await code { _ = try await session.read(ref(central, "nus.rx")) }
        XCTAssertEqual(result, "GATT_STATUS_FAILED")
        client.close()
    }

    func testReadWhileNotifyingTakesFirstValueAndDeliversBoth() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        try await session.subscribe(value)
        let notes = collect(session.notifications(for: value))
        central.peripheral.readNotify(on: true)
        _ = try await session.read(value)
        let both = await waitUntil { notes.values.count == 2 }
        XCTAssertTrue(both)
        client.close()
    }

    func testReadWithoutSubscriptionDoesNotDeliverNotification() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        let notes = collect(session.notifications(for: value))
        _ = try await session.read(value)
        await Support.sleep(realMilliseconds: 50)
        XCTAssertTrue(notes.values.isEmpty)
        client.close()
    }

    func testQueuedOperationsRunOneAtATimeInOrder() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        async let first = session.read(value)
        async let second = session.read(value)
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.count, 4)
        XCTAssertEqual(b.count, 4)
        XCTAssertNotEqual(a, b)
        client.close()
    }

    // MARK: subscribe

    func testSubscribeNotifyUnsubscribe() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        var actives: [Set<CharacteristicRef>] = []
        let stream = session.activeSubscriptionsFlow.subscribe()
        let watcher = Task { @BLECoreActor in for await set in stream { actives.append(set) } }
        let notes = collect(session.notifications(for: value))
        try await session.subscribe(value)
        XCTAssertEqual(session.snapshot().subscriptions, [value])
        central.peripheral.notify(count: 3)
        let three = await waitUntil { notes.values.count == 3 }
        XCTAssertTrue(three)
        try await session.unsubscribe(value)
        XCTAssertTrue(session.snapshot().subscriptions.isEmpty)
        central.peripheral.notify(count: 2)
        await Support.sleep(realMilliseconds: 100)
        XCTAssertEqual(notes.values.count, 3)
        XCTAssertEqual(actives, [[], [value], []])
        watcher.cancel()
        client.close()
    }

    func testSubscribeTwiceIsIdempotent() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        var actives: [Set<CharacteristicRef>] = []
        let stream = session.activeSubscriptionsFlow.subscribe()
        let watcher = Task { @BLECoreActor in for await set in stream { actives.append(set) } }
        let notes = collect(session.notifications(for: value))
        try await session.subscribe(value)
        try await session.subscribe(value)
        central.peripheral.notify(count: 2)
        let two = await waitUntil { notes.values.count == 2 }
        XCTAssertTrue(two)
        await Support.sleep(realMilliseconds: 50)
        XCTAssertEqual(notes.values.count, 2)
        XCTAssertEqual(actives, [[], [value]])
        watcher.cancel()
        client.close()
    }

    func testSubscribeToCharacteristicWithoutNotifyFailsAndLeavesNoIntent() async throws {
        let (client, central, session) = try await makeReady()
        let control = ref(central, "probe.control")
        let result = await code { try await session.subscribe(control) }
        XCTAssertEqual(result, "GATT_STATUS_FAILED")
        XCTAssertTrue(session.snapshot().subscriptions.isEmpty)
        XCTAssertTrue(session.activeSubscriptionsFlow.value.isEmpty)
        client.close()
    }

    func testUnsubscribeWithoutSubscriptionIsNoOp() async throws {
        let (client, central, session) = try await makeReady()
        try await session.unsubscribe(ref(central, "probe.value"))
        client.close()
    }

    func testCallerCancellationKeepsSubscribeAndItsIntent() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        let caller = Task { @BLECoreActor in try await session.subscribe(value) }
        caller.cancel()
        _ = await caller.result
        let active = await waitUntil { session.activeSubscriptionsFlow.value == [value] }
        XCTAssertTrue(active)
        XCTAssertEqual(session.snapshot().subscriptions, [value])
        client.close()
    }

    // MARK: 연결이 끝날 때, 복원

    func testActiveSetEmptiesOnLinkLossAndIntentIsRestoredBeforeReady() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        let value = ref(central, "probe.value")
        try await session.subscribe(value)
        var restoredWhileConfiguring = false
        let states = session.state.subscribe()
        let watcher = Task { @BLECoreActor in
            for await state in states {
                if case .ready = state, session.activeSubscriptionsFlow.value == [value] { restoredWhileConfiguring = true }
            }
        }
        central.peripheral.linkDropHide(milliseconds: 200)
        let dropped = await waitUntil { session.activeSubscriptionsFlow.value.isEmpty }
        XCTAssertTrue(dropped)
        XCTAssertEqual(session.snapshot().subscriptions, [value])
        let back = await waitUntil { isReady(session) && session.activeSubscriptionsFlow.value == [value] }
        XCTAssertTrue(back)
        XCTAssertTrue(restoredWhileConfiguring)
        let notes = collect(session.notifications(for: value))
        central.peripheral.notify(count: 1)
        let one = await waitUntil { notes.values.count == 1 }
        XCTAssertTrue(one)
        watcher.cancel()
        client.close()
    }

    func testUserDisconnectDropsIntentAndActiveSet() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        try await session.subscribe(value)
        await session.disconnect()
        XCTAssertTrue(session.snapshot().subscriptions.isEmpty)
        XCTAssertTrue(session.activeSubscriptionsFlow.value.isEmpty)
        let after = await code { _ = try await session.read(value) }
        XCTAssertEqual(after, "NOT_READY")
        client.close()
    }

    func testCloseKeepsIntentInSnapshotAndEndsNotificationStreams() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        try await session.subscribe(value)
        let stream = session.notifications(for: value)
        client.close()
        var ended = true
        for await _ in stream { ended = false }
        XCTAssertTrue(ended)
        XCTAssertEqual(session.snapshot().subscriptions, [value])
    }

    func testRestoreFailureRaisesEventAndKeepsActiveEmpty() async throws {
        let (client, central, session) = try await makeReady(autoReconnect: true)
        let value = ref(central, "probe.value")
        try await session.subscribe(value)
        // 가짜 기기가 새 연결에서 notify 를 거절하게 하는 대신, 세션이 모르는 참조를 의도에 넣어 새 탐색 결과에 없는 경우를 만든다
        let ghost = CharacteristicRef(service: value.service, uuid: BLEUUID(string: "abcd")!, instanceIndex: 0)
        session.injectIntentForTesting(ghost)
        let events = client.events
        var failed: [CharacteristicRef] = []
        let watcher = Task { @BLECoreActor in
            for await event in events {
                if case .subscriptionRestoreFailed(_, let characteristic, let failure) = event {
                    XCTAssertEqual(failure.code.value, "CHARACTERISTIC_NOT_FOUND")
                    failed.append(characteristic)
                }
            }
        }
        central.peripheral.linkDropHide(milliseconds: 100)
        _ = await waitUntil { session.activeSubscriptionsFlow.value.isEmpty }
        let back = await waitUntil { isReady(session) && session.activeSubscriptionsFlow.value == [value] }
        XCTAssertTrue(back)
        XCTAssertEqual(failed, [ghost])
        XCTAssertEqual(session.snapshot().subscriptions, [value])
        watcher.cancel()
        client.close()
    }
}

/// 알림 스트림 수집기
@BLECoreActor
private final class Collector {
    private(set) var values: [Data] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<Data>) {
        task = Task { @BLECoreActor [weak self] in
            for await value in stream { self?.values.append(value) }
        }
    }

    deinit { task?.cancel() }
}
