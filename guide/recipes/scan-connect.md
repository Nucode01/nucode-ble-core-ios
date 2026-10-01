# 레시피: 스캔과 연결

예시가 쓰는 `NUS` · `Battery` · `waitUntilReady` 는 [빠른 시작](../README.md#3-빠른-시작)에 있습니다.

## 어댑터 상태 보여 주기

**언제 쓰나.** 블루투스가 꺼져 있거나 권한이 없을 때 화면에 안내를 띄울 때.

<!-- snippet: adapter-watch -->
```swift
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
```

- 명령을 부르기 전에 `ready` 를 확인할 필요는 없습니다. 쓸 수 없으면 명령이 `ADAPTER_UNAVAILABLE` · `PERMISSION_DENIED` · `BLE_UNSUPPORTED` 를 던집니다.
  상태 안내는 사용자를 위한 것이고, 판정은 라이브러리가 합니다.
- `.unauthorized(canRequest: false)` 는 사용자가 거부했거나(설정 앱으로 안내) Info.plist 문구가 없는 경우(앱 수정)입니다.

## 스캔 필터

<!-- snippet: scan-filters -->
```swift
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
```

| 필드 | 어디서 거르나 | 비고 |
|---|---|---|
| `serviceUUIDs` | iOS 가 거릅니다 | **백그라운드 스캔은 이것만 동작합니다.** 필터 없는 스캔은 백그라운드에서 아무것도 찾지 못합니다 |
| `namePrefix` | 라이브러리가 거릅니다 | 광고의 local name 만 봅니다(시스템이 캐시한 기기 이름은 보지 않습니다). 백그라운드 광고에는 이름이 없는 경우가 많습니다 |
| `manufacturerData` · `serviceData` | 라이브러리가 거릅니다 | `data` 가 없으면 ID 만 맞으면 됩니다. 있으면 광고 값의 **앞부분**이 `data` 와 같아야 하고, `mask` 의 0 비트는 비교하지 않습니다 |
| `ScanOptions.mode` | — | iOS 에는 스캔 세기 설정이 없습니다. `.lowLatency` 만 "같은 기기 광고를 반복 보고"를 켜고, 나머지는 같습니다 |

- 스캔은 한 번에 하나입니다. 스캔 중에 **같은** 요청으로 `startScan` 하면 아무 일 없이 성공하고, **다른** 요청이면 `SCAN_ALREADY_RUNNING` 입니다. 조건을 바꾸려면 `stopScan()` 뒤 다시 시작합니다.
- `stopScan()` 은 멱등입니다. 여러 번 불러도 됩니다.
- 스캔 중 블루투스가 꺼지거나 권한을 잃으면 스캔이 끝나고 `scanStates` 가 `.failed(SCAN_STOPPED_BY_ADAPTER)` 가 됩니다. 다시 켜져도 **자동으로 재개하지 않습니다.**

## 조건에 맞는 첫 기기 찾기

**언제 쓰나.** 주변에 대상 기기가 하나라고 가정할 수 있을 때(개발 · 공장 · 1:1 제품).

<!-- snippet: scan-first -->
```swift
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
```

## 스캔 목록 만들기

**언제 쓰나.** 사용자가 목록에서 기기를 고르게 할 때.

<!-- snippet: scan-list -->
```swift
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
```

- `.balanced`(기본값)에서는 한 기기가 스캔마다 대략 한 번 보고됩니다. RSSI 를 계속 갱신하는 화면이면 `ScanOptions(mode: .lowLatency)` 를 쓰세요(배터리를 더 씁니다).
- 스캔 결과의 `advertisement` 에 `localName` · `serviceUUIDs` · `manufacturerData`(회사 ID → 값) · `serviceData` · `txPower` · `isConnectable` 이 있습니다.
  광고 원본 바이트는 iOS 가 주지 않습니다.

## 고른 기기 기억하기

<!-- snippet: save-id -->
```swift
/// PeripheralID 는 기기마다 iOS 가 이 앱에 준 UUID 문자열이다. 그대로 저장하고 되살린다
func remember(_ id: PeripheralID) {
    UserDefaults.standard.set(id.rawValue, forKey: "pairedDevice")
}

func savedDevice() -> PeripheralID? {
    UserDefaults.standard.string(forKey: "pairedDevice").map(PeripheralID.init(rawValue:))
}
```

ID 는 이 앱 · 이 폰에서만 의미가 있습니다([핵심 개념 3.2](../concepts.md#32-peripheralid)).

## 연결하고 Ready 기다리기

```swift
let session = try await client.connect(id, options: ConnectOptions())
try await waitUntilReady(session)
```

`connect()` 가 **던지는** 경우(그 자리에서 알 수 있는 실패):

| 코드 | 원인 |
|---|---|
| `ADAPTER_UNAVAILABLE` · `PERMISSION_DENIED` · `BLE_UNSUPPORTED` | 어댑터 · 권한 |
| `PERIPHERAL_NOT_FOUND` | 저장된 ID 의 기기를 시스템도 모르고 3초 스캔에도 없음 |
| `CONNECT_DURING_DISCONNECT` | 같은 기기가 해제 정리 중. 잠시 뒤 다시 |
| `CONNECTION_OPTIONS_CONFLICT` | 같은 기기에 다른 `autoReconnect` 로 연결 중 |
| `CLIENT_CLOSED` | 닫힌 client |

같은 기기에 **같은 옵션**으로 `connect()` 를 여러 번 부르면 진행 중인 시도에 합류하고 바로 반환합니다. 이미 `ready` 여도 마찬가지입니다.
화면마다 `connect()` 를 불러도 연결이 두 번 생기지 않습니다.

나머지(링크 실패 · 시간 초과 · 탐색 실패)는 `connectionStates` 의 `.disconnected(.failed(…))` 로 옵니다. `waitUntilReady` 가 그것을 던져 줍니다.

## 실패하면 다시 시도하기

**언제 쓰나.** `autoReconnect: false` 로 연결하면서, 일시적인 실패는 몇 번 더 해 보고 싶을 때. 라이브러리는 재시도 횟수 · 간격을 정하지 않습니다.

<!-- snippet: connect-retry -->
```swift
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
```

- `retryability` 가 `.never`(옵션 · ID 문제)나 `.afterEnvironmentChange`(블루투스 · 권한)면 다시 해도 같으므로 멈춥니다.
- 앱이 정한 시간이 지나 포기할 때는 `disconnect()` 로 진행 중인 시도를 거둬야 다음 `connect()` 가 새로 시작합니다.
- 끊겨도 계속 붙어 있어야 하는 기기라면 이 방법 대신 `autoReconnect: true` 를 쓰세요([연결 유지](connection.md)).

## 탐색 결과에서 characteristic 찾기

**언제 쓰나.** UUID 를 미리 모르거나, 같은 UUID 가 여러 개라 `instanceIndex` 를 골라야 할 때. UUID 를 알면 `NUS` 처럼 바로 만드는 편이 간단합니다.

<!-- snippet: find-characteristic -->
```swift
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
```

`services` 스트림의 첫 값은 마지막 탐색 결과입니다. 탐색 전이면 빈 배열이므로 `ready` 뒤에 부르세요.
연결이 끊겨도 마지막 탐색 결과는 지우지 않습니다.
