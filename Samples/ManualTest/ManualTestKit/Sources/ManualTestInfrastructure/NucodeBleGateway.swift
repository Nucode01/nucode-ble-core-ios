import Foundation
import ManualTestDomain
import NucodeBleCore
import os

/// `BleGateway` 의 NucodeBleCore 구현. client 는 앱당 하나, 앱 수명 동안 둔다(ios-design §8).
/// 알림 경로는 둘이다: 등록 기기의 등록 characteristic 은 `onNotification`(복원 구간 포함), 나머지는 세션의 `notifications(for:)`. 같은 알림을 두 번 세지 않게 나눈다.
public final class NucodeBleGateway: BleGateway {
    public let events: AsyncStream<GatewayEvent>
    private let continuation: AsyncStream<GatewayEvent>.Continuation
    private let client: BLEClient
    private let tracking = OSAllocatedUnfairLock(initialState: Tracking())

    private struct Tracking {
        /// activeSubscriptions 를 보고 있는 세션
        var observed: Set<DeviceId> = []
        /// notifications(for:) 를 모으는 (기기, characteristic)
        var collecting: Set<Key> = []
        /// onNotification 이 나르는 (기기, characteristic)
        var registered: Set<Key> = []
    }

    private struct Key: Hashable {
        let device: DeviceId
        let characteristic: ProbeCharacteristic
    }

    /// 같은 프로세스에서 같은 restoreIdentifier 로 두 번 만들면 라이브러리가 trap 한다
    public init(restoreIdentifier: String?) {
        (events, continuation) = AsyncStream.makeStream(of: GatewayEvent.self)
        client = BLEClient(options: BLEOptions(restoreIdentifier: restoreIdentifier))
    }

    public func start(registration: DeviceRegistration?) {
        forward(client.adapterStates) { .adapter(Translate.adapter($0)) }
        forward(client.scanStates) { .scan(Translate.scan($0)) }
        forward(client.scanResults) { .discovered(Translate.device($0, at: Date())) }
        forward(client.events) { Translate.event($0) }
        if let registration {
            // register·onNotification 은 start() 전에만 된다
            client.register(
                Translate.peripheral(registration.deviceId),
                options: ConnectOptions(autoReconnect: registration.autoReconnect),
                subscribe: registration.subscribe.map(Translate.ref)
            )
            tracking.withLock {
                $0.registered = Set(registration.subscribe.map { Key(device: registration.deviceId, characteristic: $0) })
            }
            client.onNotification(queue: .main) { [continuation] id, ref, value in
                guard let characteristic = Translate.characteristic(ref) else { return }
                continuation.yield(.notification(DeviceId(id.rawValue), characteristic, value))
            }
            if let session = try? client.session(for: Translate.peripheral(registration.deviceId)) {
                observe(session, registration.deviceId)
            }
        }
        client.start()
    }

    public func snapshot() async -> GatewaySnapshot {
        Translate.snapshot(await client.snapshot())
    }

    public func startScan(_ criteria: ScanCriteria) async throws {
        try await translating { try await client.startScan(request: Translate.criteria(criteria)) }
    }

    public func stopScan() async {
        await client.stopScan()
    }

    public func connect(_ id: DeviceId, autoReconnect: Bool) async throws {
        try await translating {
            try await session(id).connect(options: ConnectOptions(autoReconnect: autoReconnect))
        }
    }

    public func disconnect(_ id: DeviceId) async {
        guard let session = try? session(id) else { return }
        await session.disconnect()
    }

    public func read(_ id: DeviceId, _ characteristic: ProbeCharacteristic) async throws -> Data {
        try await translating { try await session(id).read(Translate.ref(characteristic)) }
    }

    public func write(_ id: DeviceId, _ characteristic: ProbeCharacteristic, value: Data) async throws -> Int {
        try await translating {
            try await session(id).write(Translate.ref(characteristic), value: value, options: WriteOptions()).bytesCompleted
        }
    }

    public func subscribe(_ id: DeviceId, _ characteristic: ProbeCharacteristic) async throws {
        try await translating {
            let session = try session(id)
            collect(session, id, characteristic)
            try await session.subscribe(Translate.ref(characteristic))
        }
    }

    public func unsubscribe(_ id: DeviceId, _ characteristic: ProbeCharacteristic) async throws {
        try await translating { try await session(id).unsubscribe(Translate.ref(characteristic)) }
    }

    // MARK: 내부

    /// 세션을 얻고 처음이면 activeSubscriptions 를 보기 시작한다
    private func session(_ id: DeviceId) throws -> any BLESession {
        let session = try client.session(for: Translate.peripheral(id))
        observe(session, id)
        return session
    }

    private func observe(_ session: any BLESession, _ id: DeviceId) {
        guard tracking.withLock({ $0.observed.insert(id).inserted }) else { return }
        forward(session.activeSubscriptions) { .activeSubscriptions(id, Translate.characteristics($0)) }
    }

    /// 구독 전에 모으기 시작한다(첫 알림을 놓치지 않게). 등록 경로가 나르는 것은 건너뛴다
    private func collect(_ session: any BLESession, _ id: DeviceId, _ characteristic: ProbeCharacteristic) {
        let key = Key(device: id, characteristic: characteristic)
        let start = tracking.withLock { t -> Bool in
            guard !t.registered.contains(key) else { return false }
            return t.collecting.insert(key).inserted
        }
        guard start else { return }
        forward(session.notifications(for: Translate.ref(characteristic))) { .notification(id, characteristic, $0) }
    }

    /// 구독은 부르는 순간 동기로 걸린다. 이후 값만 Task 가 나른다
    private func forward<T: Sendable>(_ stream: AsyncStream<T>, _ map: @escaping @Sendable (T) -> GatewayEvent) {
        Task { [continuation] in
            for await value in stream { continuation.yield(map(value)) }
        }
    }

    private func translating<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Translate.error(error) }
    }
}
