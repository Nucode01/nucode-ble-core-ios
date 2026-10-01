import BleContract
import BleContractBackend
import Foundation
import NucodeBleCore

/// 실제 iPhone 과 nRF52840 시험 펌웨어로 잇는 device 백엔드. 시나리오마다 새 클라이언트를 쓰고 라이브러리 설정은 기본값이다.
/// 기기 사건은 `probe.control` 에 펌웨어 명령을 공개 write 로 쓰고, `rxCheck` 는 공개 read 로 한다.
enum DeviceBackend {
    struct SetupError: Error, CustomStringConvertible {
        let description: String
    }

    static let adapterTimeout: Duration = .seconds(10)
    static let scanTimeout: Duration = .seconds(30)
    /// 기기가 링크 끊김을 알아채고 다시 광고할 시간
    static let settle: Duration = .milliseconds(1500)

    /// 어댑터 ready 대기와 대상 기기 스캔으로 기록 전 확보를 끝내고 백엔드를 만든다
    static func make(scenario: Scenario) async throws -> ClientBackend {
        let profile = scenario.peripheral
        let client = BLEClientFactory.make(options: BLEOptions())
        client.start()
        do {
            try await awaitAdapterReady(client)
            let targetID = try await discover(client, profile: profile)
            let session = try client.session(for: targetID)
            let control = try controlRef(profile)
            let hooks = BackendHooks(
                deviceEvent: { event in
                    guard let command = command(for: event) else { return }
                    _ = try await session.write(
                        control,
                        value: Data(command.utf8),
                        options: WriteOptions(mode: .withResponse)
                    )
                },
                rxCheck: {
                    let data = try await session.read(control)
                    return (String(data: data, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                },
                setAdapter: { _ in throw SetupError(description: "adapter 단계는 sim 전용이다") },
                tearDown: { try? await Task.sleep(for: settle) }
            )
            return try ClientBackend(client: client, profile: profile, targetID: targetID, hooks: hooks)
        } catch {
            client.close()
            throw error
        }
    }

    /// 펌웨어 명령. `rxCheck` 는 사건이 아니라 읽기라 쓰지 않는다
    static func command(for event: DeviceEvent) -> String? {
        switch event {
        case .linkDrop: "LINK_DROP"
        case .linkDropHide(let ms): "LINK_DROP_HIDE \(ms)"
        case .notify(let count): "NOTIFY \(count)"
        case .readNotify(let on): "READ_NOTIFY \(on ? "ON" : "OFF")"
        case .rxCheck: nil
        }
    }

    private static func controlRef(_ profile: PeripheralProfile) throws -> CharacteristicRef {
        guard let control = profile.characteristics["probe.control"],
              let service = BLEUUID(string: control.service),
              let uuid = BLEUUID(string: control.uuid)
        else { throw SetupError(description: "기기 정의에 probe.control 이 없다") }
        return CharacteristicRef(service: ServiceRef(uuid: service, instanceIndex: 0), uuid: uuid, instanceIndex: 0)
    }

    private static func awaitAdapterReady(_ client: any BLEClient) async throws {
        try await withTimeout(adapterTimeout, what: "어댑터 ready") {
            for await state in client.adapterStates {
                switch state {
                case .ready: return
                case .unknown, .resetting: continue
                default: throw SetupError(description: "Bluetooth 를 쓸 수 없다: \(state)")
                }
            }
            throw SetupError(description: "어댑터 상태 스트림이 끝났다")
        }
    }

    /// 광고 중인 시험 기기를 찾는다. 앞 시나리오의 링크가 아직 남아 있으면 광고가 다시 시작될 때까지 기다린다.
    private static func discover(_ client: any BLEClient, profile: PeripheralProfile) async throws -> PeripheralID {
        let advertised = profile.services.values.filter(\.advertised).compactMap { BLEUUID(string: $0.uuid) }
        let request = ScanRequest(filter: NucodeBleCore.ScanFilter(serviceUUIDs: advertised))
        let results = client.scanResults
        try await client.startScan(request: request)
        do {
            let id = try await withTimeout(scanTimeout, what: "기기 스캔(\(profile.advertisedName))") {
                for await result in results where result.advertisement.localName == profile.advertisedName {
                    return result.peripheralID
                }
                throw SetupError(description: "스캔 결과 스트림이 끝났다")
            }
            await client.stopScan()
            return id
        } catch {
            await client.stopScan()
            throw error
        }
    }

    private static func withTimeout<T: Sendable>(
        _ limit: Duration,
        what: String,
        _ body: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw SetupError(description: "\(what) 시간 초과")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}
