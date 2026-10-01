import BleContract
import Foundation
import NucodeBleCore

/// 플랫폼마다 다른 부분. sim 은 가짜 기기·가짜 어댑터, device 는 제어 characteristic 과 실제 기기다.
public struct BackendHooks: Sendable {
    public let deviceEvent: @Sendable (DeviceEvent) async throws -> Void
    public let rxCheck: @Sendable () async throws -> String
    public let setAdapter: @Sendable (AdapterValue) async throws -> Void
    public let tearDown: @Sendable () async -> Void

    public init(
        deviceEvent: @escaping @Sendable (DeviceEvent) async throws -> Void,
        rxCheck: @escaping @Sendable () async throws -> String,
        setAdapter: @escaping @Sendable (AdapterValue) async throws -> Void,
        tearDown: @escaping @Sendable () async -> Void = {}
    ) {
        self.deviceEvent = deviceEvent
        self.rxCheck = rxCheck
        self.setAdapter = setAdapter
        self.tearDown = tearDown
    }
}

public enum BackendError: Error, Sendable {
    /// 아직 공개 API 에 이어지지 않은 호출
    case unsupported(String)
}

/// 공개 API(`BLEClient`)를 `ScenarioBackend` 로 잇는 공통 부분. sim 러너와 device 러너가 같은 소스를 쓴다.
/// `client.start()` 는 부르는 쪽이 `attach` 전에 한다(어댑터·스캔 레인의 첫 값이 `Ready`·`Idle` 이 되도록).
public final class ClientBackend: ScenarioBackend, @unchecked Sendable {
    private let client: any BLEClient
    private let profile: PeripheralProfile
    private let targetID: PeripheralID
    private let hooks: BackendHooks
    private let session: any BLESession
    /// (서비스 UUID, characteristic UUID) → 기호 이름. 기기 정의에 있는 것만
    private let symbols: [Key: String]

    private struct Key: Hashable {
        let service: BLEUUID
        let characteristic: BLEUUID
    }

    private let lock = NSLock()
    private var observers: [Task<Void, Never>] = []

    /// 첫 단계 전에 대상 기기의 세션을 얻는다(contract/README §snapshot)
    public init(client: any BLEClient, profile: PeripheralProfile, targetID: PeripheralID, hooks: BackendHooks) throws {
        self.client = client
        self.profile = profile
        self.targetID = targetID
        self.hooks = hooks
        var table: [Key: String] = [:]
        for (symbol, characteristic) in profile.characteristics {
            guard let service = BLEUUID(string: characteristic.service), let uuid = BLEUUID(string: characteristic.uuid) else {
                throw ContractError("not a UUID: \(symbol)")
            }
            table[Key(service: service, characteristic: uuid)] = symbol
        }
        symbols = table
        session = try client.session(for: targetID)
    }

    // MARK: 관찰

    public func attach(_ observer: ScenarioObserver) async {
        let targetID = targetID
        let streams = (
            events: client.events,
            adapter: client.adapterStates,
            scan: client.scanStates,
            results: client.scanResults,
            services: session.services,
            active: session.activeSubscriptions
        )
        let tasks = [
            Task {
                for await event in streams.events {
                    if case .connection(let id, let state) = event, id == targetID {
                        observer.state(Self.render(state))
                    }
                }
            },
            Task {
                for await state in streams.adapter { observer.adapter(Self.adapterValue(state)) }
            },
            Task {
                for await state in streams.scan { observer.scan(Self.render(state)) }
            },
            Task {
                for await result in streams.results where result.peripheralID == targetID {
                    observer.scanResultForTarget()
                }
            },
            Task { [symbols] in
                for await list in streams.services {
                    let found = list.flatMap { service in
                        service.characteristics.compactMap { symbols[Key(service: service.ref.uuid, characteristic: $0.ref.uuid)] }
                    }
                    observer.services(found)
                }
            },
            Task { [symbols] in
                for await refs in streams.active {
                    observer.activeSubscriptions(refs.compactMap { symbols[Key(service: $0.service.uuid, characteristic: $0.uuid)] })
                }
            },
        ]
        // 알림: notify 속성이고 runnerOnly 아닌 characteristic 마다 스트림을 하나씩 받아 `notify` 레인으로 잇는다
        let notifying = profile.characteristics.filter { $0.value.properties.contains("notify") && !$0.value.runnerOnly }
        var notifyTasks: [Task<Void, Never>] = []
        for (symbol, characteristic) in notifying {
            guard let ref = try? Self.ref(characteristic) else { continue }
            let stream = session.notifications(for: ref)
            notifyTasks.append(Task { for await _ in stream { observer.notification(symbol) } })
        }
        lock.withLock { observers = tasks + notifyTasks }
    }

    private static func ref(_ characteristic: Characteristic) throws -> CharacteristicRef {
        guard let service = BLEUUID(string: characteristic.service), let uuid = BLEUUID(string: characteristic.uuid) else {
            throw ContractError("not a UUID: \(characteristic.symbol)")
        }
        return CharacteristicRef(service: ServiceRef(uuid: service, instanceIndex: 0), uuid: uuid, instanceIndex: 0)
    }

    // MARK: 호출

    public func connect(autoReconnect: Bool) async throws -> CallOutcome {
        try await outcome { try await session.connect(options: ConnectOptions(autoReconnect: autoReconnect)) }
    }

    public func disconnect() async throws -> CallOutcome {
        await session.disconnect()
        return .ok
    }

    public func read(_ char: Characteristic) async throws -> CallOutcome {
        let ref = try Self.ref(char)
        return try await outcome { _ = try await session.read(ref) }
    }

    public func write(_ char: Characteristic, bytes: [UInt8], withResponse: Bool, chunking: BleContract.WriteChunking) async throws -> CallOutcome {
        let ref = try Self.ref(char)
        let chunkingOption: NucodeBleCore.WriteChunking
        switch chunking {
        case .automatic: chunkingOption = .automatic
        case .disabled: chunkingOption = .disabled
        case .fixed(let bytes): chunkingOption = .fixed(bytes)
        }
        let options = WriteOptions(mode: withResponse ? .withResponse : .withoutResponse, chunking: chunkingOption)
        return try await outcome { _ = try await session.write(ref, value: Data(bytes), options: options) }
    }

    public func subscribe(_ char: Characteristic) async throws -> CallOutcome {
        let ref = try Self.ref(char)
        return try await outcome { try await session.subscribe(ref) }
    }

    public func unsubscribe(_ char: Characteristic) async throws -> CallOutcome {
        let ref = try Self.ref(char)
        return try await outcome { try await session.unsubscribe(ref) }
    }

    public func startScan(filter: BleContract.ScanFilter) async throws -> CallOutcome {
        let uuids = try filter.services.map { ref -> BLEUUID in
            guard let uuid = BLEUUID(string: ref.uuid) else { throw ContractError("not a UUID: \(ref.uuid)") }
            return uuid
        }
        let request = ScanRequest(filter: NucodeBleCore.ScanFilter(serviceUUIDs: uuids, namePrefix: filter.name))
        return try await outcome { try await client.startScan(request: request) }
    }

    public func stopScan() async throws -> CallOutcome {
        await client.stopScan()
        return .ok
    }

    public func snapshot() async throws -> BleContract.ClientSnapshot {
        let snapshot = await client.snapshot()
        return BleContract.ClientSnapshot(
            adapter: Self.adapterValue(snapshot.adapter),
            scanning: snapshot.scanning,
            sessions: snapshot.sessions.map { session in
                BleContract.ClientSnapshot.Session(
                    isTarget: session.peripheralID == targetID,
                    state: Self.render(session.state),
                    subscriptions: session.subscriptions.compactMap {
                        symbols[Key(service: $0.service.uuid, characteristic: $0.uuid)]
                    }
                )
            }
        )
    }

    public func close() async throws -> CallOutcome {
        client.close()
        return .ok
    }

    // MARK: 기기·어댑터 (플랫폼 hooks)

    public func performDeviceEvent(_ event: DeviceEvent) async throws {
        try await hooks.deviceEvent(event)
    }

    public func rxCheck() async throws -> String {
        try await hooks.rxCheck()
    }

    public func setAdapter(_ value: AdapterValue) async throws {
        try await hooks.setAdapter(value)
    }

    public func tearDown() async {
        await session.disconnect()
        client.close()
        await hooks.tearDown()
        let tasks = lock.withLock { observers }
        for task in tasks { task.cancel() }
    }

    // MARK: 변환

    /// 공개 실패 타입은 `.failed`, 그 밖의 오류는 그대로 던져 `EXCEPTION:<타입>` 이 되게 한다
    private func outcome(_ body: () async throws -> Void) async throws -> CallOutcome {
        do {
            try await body()
            return .ok
        } catch let error as BLEError {
            return .failed(code: error.failure.code.value)
        }
    }

    static func render(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected(let reason):
            switch reason {
            case .initial: "Disconnected(Initial)"
            case .requested: "Disconnected(Requested)"
            case .clientClosed: "Disconnected(ClientClosed)"
            case .failed(let failure): "Disconnected(Failed:\(failure.code.value))"
            }
        case .connecting: "Connecting"
        case .discoveringServices: "DiscoveringServices"
        case .configuring: "Configuring"
        case .ready: "Ready"
        case .disconnecting: "Disconnecting"
        case .recovering(let failure): "Recovering(\(failure.code.value))"
        }
    }

    static func render(_ state: ScanState) -> String {
        switch state {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .failed(let failure): "Idle(Failed:\(failure.code.value))"
        }
    }

    static func adapterValue(_ state: AdapterState) -> AdapterValue {
        switch state {
        case .unknown: .unknown
        case .unsupported: .unsupported
        case .unauthorized(let canRequest): canRequest ? .unauthorizedCanRequest : .unauthorizedDenied
        case .poweredOff: .poweredOff
        case .resetting: .resetting
        case .ready: .ready
        }
    }
}
