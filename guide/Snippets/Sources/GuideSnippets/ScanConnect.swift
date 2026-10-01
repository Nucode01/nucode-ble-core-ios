import Foundation
import NucodeBleCore

// region guide:adapter-watch
/// 어댑터 상태를 화면 문구로 바꾼다. `start()` 전에는 `.unknown` 이다
func adapterMessage(_ state: AdapterState) -> String? {
    switch state {
    case .ready: return nil
    case .unknown, .resetting: return "블루투스 상태 확인 중"
    case .poweredOff: return "블루투스를 켜 주세요"
    case .unauthorized(canRequest: true): return "블루투스 권한을 허용해 주세요"
    case .unauthorized(canRequest: false): return "설정 > 개인정보 보호 > Bluetooth 에서 권한을 켜 주세요"
    case .unsupported: return "이 기기는 BLE 를 지원하지 않습니다"
    }
}

func watchAdapter(_ client: BLEClient) -> Task<Void, Never> {
    Task {
        for await state in client.adapterStates {
            print("adapter:", adapterMessage(state) ?? "ready")
        }
    }
}
// endregion

// region guide:scan-filters
/// 필터 항목(serviceUUIDs · manufacturerData · serviceData)은 서로 OR 이고, namePrefix 만 AND 로 붙는다
let byService = ScanFilter(serviceUUIDs: [NUS.service.uuid])

let byNamePrefix = ScanFilter(namePrefix: "Nordic_")

/// 제조사 ID 0x0059(Nordic) 광고 중 앞 두 바이트가 0x01 0x?? 인 것. mask 0x00 자리는 비교하지 않는다
let byManufacturer = ScanFilter(manufacturerData: [
    ManufacturerDataFilter(companyID: 0x0059, data: Data([0x01, 0x00]), mask: Data([0xFF, 0x00])),
])

/// service UUID 로 거르고 그중 이름이 "Sensor-" 로 시작하는 것만
let serviceAndName = ScanFilter(serviceUUIDs: [NUS.service.uuid], namePrefix: "Sensor-")

/// 모두 비우면 주변의 모든 광고. `.lowLatency` 만 같은 기기의 광고를 반복해서 보고한다(RSSI 갱신용)
let everything = ScanRequest(filter: ScanFilter(), options: ScanOptions(mode: .lowLatency))
// endregion

// region guide:scan-first
/// 조건에 맞는 첫 기기를 `timeout` 안에 찾는다. 못 찾으면 nil. 어느 쪽이든 스캔은 멈춘다
func findFirst(_ client: BLEClient, filter: ScanFilter, timeout: Duration = .seconds(10)) async throws -> ScanResult? {
    let results = client.scanResults // startScan 전에 구독해야 첫 결과를 놓치지 않는다
    try await client.startScan(request: ScanRequest(filter: filter))
    let found = await withTaskGroup(of: ScanResult?.self) { group in
        group.addTask {
            for await result in results { return result }
            return nil
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
    await client.stopScan()
    return found
}
// endregion

// region guide:scan-list
/// 목록 화면용: `duration` 동안 본 기기를 기기별 최신 결과 하나로 모아 신호 세기 순으로 돌려준다
func collectDevices(_ client: BLEClient, filter: ScanFilter, for duration: Duration) async throws -> [ScanResult] {
    let results = client.scanResults
    try await client.startScan(request: ScanRequest(filter: filter))
    let collector = Task {
        var latest: [PeripheralID: ScanResult] = [:]
        for await result in results { latest[result.peripheralID] = result } // 취소되면 루프가 끝난다
        return latest
    }
    try? await Task.sleep(for: duration)
    await client.stopScan()
    collector.cancel()
    return await collector.value.values.sorted { $0.rssi > $1.rssi }
}
// endregion

// region guide:save-id
/// PeripheralID 는 기기마다 iOS 가 이 앱에 준 UUID 문자열이다. 그대로 저장하고 되살린다
func remember(_ id: PeripheralID) {
    UserDefaults.standard.set(id.rawValue, forKey: "pairedDevice")
}

func savedDevice() -> PeripheralID? {
    UserDefaults.standard.string(forKey: "pairedDevice").map(PeripheralID.init(rawValue:))
}
// endregion

// region guide:connect-retry
/// autoReconnect 없이 연결하되, 다시 해 볼 만한 실패는 몇 번 더 시도한다
func connectWithRetry(_ client: BLEClient, _ id: PeripheralID, attempts: Int = 3) async throws -> any BLESession {
    var lastError: any Error = CancellationError()
    for attempt in 1...attempts {
        let session = try client.session(for: id)
        do {
            try await session.connect(options: ConnectOptions())
            try await waitUntilReady(session, timeout: .seconds(40))
            return session
        } catch let error as BLEError where error.failure.retryability != .never
            && error.failure.retryability != .afterEnvironmentChange {
            lastError = error
        } catch is ReadyTimeout {
            lastError = ReadyTimeout()
            await session.disconnect() // 앱이 정한 시간이 지났으면 진행 중인 시도를 거둔다
        }
        try await Task.sleep(for: .seconds(attempt))
    }
    throw lastError
}
// endregion

// region guide:find-characteristic
/// 탐색 결과에서 characteristic 을 찾는다. 참조를 미리 알면(위 `NUS`) 이 과정은 필요 없다
func findCharacteristic(_ uuid: BLEUUID, inService service: BLEUUID, of session: any BLESession) async -> CharacteristicRef? {
    for await services in session.services { // 첫 값은 마지막 탐색 결과다
        return services
            .first { $0.ref.uuid == service }?
            .characteristics
            .first { $0.ref.uuid == uuid }?
            .ref
    }
    return nil
}
// endregion
