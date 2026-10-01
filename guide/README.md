# NucodeBleCore iOS 개발자 가이드 (0.2.x)

NucodeBleCore 를 처음 보는 iOS 개발자가 이 가이드만 따라 해서 앱에 붙일 수 있도록 쓴 안내서입니다.
설치부터 스캔 · 연결 · 읽기 · 쓰기 · 알림 수신 · 실패 처리 · 화면 연동 · 상태 복원까지 순서대로 다룹니다.

> **예시 코드에 대해.** 이 문서의 Swift 예시는 [`Snippets/Sources/GuideSnippets/`](Snippets/Sources/GuideSnippets)의
> 같은 이름 `// region guide:…` 블록과 글자 그대로 같습니다. 그 패키지는 라이브러리 밖의 소비자 자리라 공개 API 만 보이며,
> `cd guide/Snippets && swift build`(macOS)와 iOS 빌드로 컴파일을 확인합니다. 문서와 소스가 같은지는 `python3 guide/check_snippets.py` 가 봅니다.
> 예시 UUID(Nordic UART Service, Battery)는 **예시**입니다. 실제 기기의 UUID 로 바꿔 쓰세요.
> 예시들이 함께 쓰는 `NUS` · `Battery` 참조와 `waitUntilReady` 는 [빠른 시작](#3-빠른-시작)에 있습니다.

## 목차

| 문서 | 내용 |
|---|---|
| [설치](install.md) | Swift Package 추가, Info.plist, 권한 팝업 시점 |
| [핵심 개념](concepts.md) | `BLEClient`·`BLESession`, ID, characteristic 참조, 상태, 실패, 스트림과 스레드, 시간 제한 |
| [레시피: 스캔과 연결](recipes/scan-connect.md) | 어댑터 상태 · 스캔 필터 · 첫 기기 찾기 · 목록 · ID 저장 · 연결과 Ready 대기 · 재시도 · characteristic 찾기 |
| [레시피: 읽기 · 쓰기 · 구독](recipes/data.md) | read · write(분할 · 응답 없음 · 고정 크기) · notify · 요청-응답 · 활성 구독 |
| [레시피: 연결 유지 · 여러 기기](recipes/connection.md) | autoReconnect · 복구 감시와 포기 · 블루투스 끄고 켜기 · 여러 기기 · 세션 다시 얻기 |
| [레시피: 실패 처리 · 이벤트 · 스냅샷](recipes/errors-diagnostics.md) | 실패 문구 · 재시도 판단 · 코드표 · CoreBluetooth 원인 · 이벤트 로그 · 스냅샷 |
| [레시피: 앱 구조에 넣기](recipes/app-integration.md) | client 소유 · SwiftUI 모델 · 상태 복원(백그라운드 재실행) · `close()` |
| [문제 해결과 한계](troubleshooting.md) | 자주 틀리는 것 · FAQ · 한계와 검증 범위 |

처음이면 이 페이지 → 설치 → 핵심 개념 → 필요한 레시피 순서로 읽으세요.

이 가이드의 패턴을 그대로 쓴 데모 앱(스캔 · 연결 · NUS 텍스트 송수신 · 자동 재연결 · 이벤트 로그)은 [`Samples/Demo`](../Samples/Demo/README.md)에 있습니다.

## 1. 소개

### 무엇인가

NucodeBleCore 는 iOS 앱이 BLE 기기(peripheral)에 **central** 로 붙을 때 쓰는 Swift 라이브러리입니다.
CoreBluetooth 를 직접 쓰면 delegate 콜백으로 흩어지는 흐름, 연결 · 탐색 · 구독 복원 순서, 끊김 뒤 재연결,
블루투스 끄고 켜기, 앱이 시스템에 의해 종료된 뒤의 상태 복원을 앱이 모두 떠안게 됩니다.
이 라이브러리는 그 일을 `async/await` API 뒤에서 처리합니다.

Android 판(`kr.co.nucode:ble-core`)과 **같은 계약**(명령의 완료 · 실패 · 상태 전이 · 실패 코드)을 지킵니다.
두 플랫폼 앱이 같은 코드 이름으로 분기하고 같은 상태 순서를 봅니다.

### 주요 기능

| 기능 | 내용 |
|---|---|
| async API | 명령은 `async throws` 함수, 상태와 수신 값은 `AsyncStream` 입니다. 상태 스트림은 구독하면 현재 값을 먼저 줍니다. |
| GATT 작업 줄 세우기 | 기기마다 read · write · 구독을 온 순서대로 하나씩 실행합니다. 여러 Task 에서 동시에 불러도 됩니다. |
| 긴 write 자동 분할 | 한 번에 보낼 수 있는 크기로 잘라 연달아 보내고, `WriteReceipt` 로 결과를 알려 줍니다. |
| 타입이 있는 실패 | 모든 실패는 `BLEError(failure: BLEFailure)` 입니다. 바뀌지 않는 `code` 와 재시도 가능성(`Retryability`)으로 분기합니다. |
| 연결 단계 관리 | 서비스 · characteristic 탐색과 구독 복원을 라이브러리가 하고 `connecting → discoveringServices → configuring → ready` 로 보여 줍니다. |
| 재연결과 구독 복원 | `autoReconnect: true` 면 끊겨도 OS 가 다시 붙일 때까지 기다리고(백그라운드 포함), 블루투스가 다시 켜지면 한 번 다시 연결합니다. 켜 둔 구독은 재연결마다 `ready` 전에 다시 켭니다. |
| 어댑터 · 권한 상태 | `AdapterState` 하나로 "지금 BLE 를 쓸 수 있는가"를 표현합니다. 아직 묻지 않은 권한과 거부된 권한을 구분합니다. |
| 상태 복원 | `restoreIdentifier` 와 `register` 로 시스템이 앱을 백그라운드에서 다시 실행했을 때 연결 · 구독 · 알림 수신을 이어받습니다. |

### 하지 않는 것

- **peripheral(서버) 역할과 광고 송출.** central 전용입니다.
- **앱 수준 프로토콜 · 파싱 · 암호화.** 바이트를 주고받을 뿐입니다.
- **권한 설명 문구와 권한 안내 화면.** 앱이 Info.plist 에 선언하고 안내합니다.
- **라이브러리 자체 재연결 시간표(백오프 · 재시도 횟수).** OS 대기 연결(`autoReconnect: true`)이나 앱이 맡습니다.
- **본딩 API, MTU 지정, 스캔 모드 세 단계.** iOS 에 대응 API 가 없습니다. 페어링은 암호화된 characteristic 에 처음 접근할 때 시스템이 띄웁니다.
- **사용자가 강제 종료한 앱의 재실행.** iOS 정책입니다.

### 요구 사항

| 항목 | 값 |
|---|---|
| 최소 버전 | iOS 17 / macOS 14 |
| 언어 | Swift 6 (strict concurrency 에서 경고 없이 쓸 수 있습니다) |
| 의존성 | 없음 (Foundation · CoreBluetooth) |
| 저장소 | `https://github.com/pdev-jay/nucode-ble-core-ios.git` (비공개. 읽기 권한이 필요합니다) |

## 2. 전체 그림

```text
 앱                                   NucodeBleCore
 ─────────────────────                ──────────────────────────────────────────
 BLEClient  (앱당 하나)  ───────────▶  어댑터 상태 · 스캔 · 이벤트 · 스냅샷 · close
   │ connect(id) / session(for: id)
   ▼
 BLESession (기기 하나를 보는 창) ───▶  연결 상태 · 서비스 · read · write · 구독
                                         │  기기마다 작업 줄 하나, 한 번에 하나씩
                                         ▼
                                      CoreBluetooth (CBCentralManager · CBPeripheral)
```

- 공개 API 는 **ID 기반**입니다. `CBPeripheral` 을 직접 만지지 않고 `PeripheralID` 와 `CharacteristicRef` 로 가리킵니다.
- 상태의 주인은 라이브러리입니다. 앱은 스트림으로 보고, 명령으로 바꿉니다.

## 3. 빠른 시작

모든 예시가 쓰는 GATT 참조입니다. 탐색 결과에서 찾지 않고 UUID 로 바로 만듭니다.

<!-- snippet: uuids -->
```swift
/// 예시 기기의 GATT 참조. Nordic UART Service(NUS) 기준이다. 실제 기기의 UUID 로 바꿔 쓴다
enum NUS {
    static let service = ServiceRef(uuid: BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
    /// 앱 → 기기 (write)
    static let rx = CharacteristicRef(service: service, uuid: BLEUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
    /// 기기 → 앱 (notify)
    static let tx = CharacteristicRef(service: service, uuid: BLEUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
}

/// 16비트 SIG UUID 는 4자리로 쓴다(Bluetooth base UUID 로 넓혀진다)
enum Battery {
    static let service = ServiceRef(uuid: BLEUUID(string: "180F")!, instanceIndex: 0)
    static let level = CharacteristicRef(service: service, uuid: BLEUUID(string: "2A19")!, instanceIndex: 0)
}
```

`connect()` 는 **연결 시도가 시작되면** 반환합니다(연결 완료가 아닙니다). `ready` 는 상태 스트림으로 기다립니다.

<!-- snippet: wait-ready -->
```swift
struct ReadyTimeout: Error {}

/// 세션이 `ready` 가 될 때까지 기다린다. 실패로 끝나면 그 `BLEError` 를, 시간이 지나면 `ReadyTimeout` 을 던진다.
/// `connect()` 의 정상 반환은 "시도가 시작됐다"는 뜻이라 이 대기가 필요하다
func waitUntilReady(_ session: any BLESession, timeout: Duration = .seconds(30)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await state in session.connectionStates {
                switch state {
                case .ready:
                    return
                case .disconnected(reason: .failed(let failure)):
                    throw BLEError(failure: failure)
                case .disconnected(reason: .requested), .disconnected(reason: .clientClosed):
                    throw CancellationError()
                default:
                    continue // connecting · discoveringServices · configuring · recovering · initial
                }
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ReadyTimeout()
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
```

스캔에서 정리까지 한 번에:

<!-- snippet: quick-start -->
```swift
// 1. 앱당 하나 만들고 앱 수명 동안 둔다
let client = BLEClient()
client.start() // 이때 CBCentralManager 가 만들어지고 권한 팝업이 뜬다

// 2. 스캔: 결과 스트림을 먼저 얻고 시작한다
let results = client.scanResults
try await client.startScan(request: ScanRequest(filter: ScanFilter(serviceUUIDs: [NUS.service.uuid])))
var found: ScanResult?
for await result in results {
    found = result
    break
}
await client.stopScan()
guard let device = found else { return }

// 3. 연결: connect 는 시도가 시작되면 반환한다. Ready 는 따로 기다린다
let session = try await client.connect(device.peripheralID, options: ConnectOptions())
try await waitUntilReady(session)

// 4. 읽기 · 쓰기 · 알림
let level = try await session.read(Battery.level)
print("battery", level.first ?? 0)

let receipt = try await session.write(NUS.rx, value: Data("hello".utf8), options: WriteOptions())
print("sent", receipt.bytesCompleted, "bytes")

let incoming = session.notifications(for: NUS.tx) // 구독 전에 받을 곳부터 연다
try await session.subscribe(NUS.tx)
for await value in incoming.prefix(3) {
    print("received", value as NSData)
}

// 5. 정리
await session.disconnect()
client.close()
```

기억할 것 세 가지:

1. **`BLEClient` 는 앱당 하나.** 화면마다 만들지 마세요. `restoreIdentifier` 를 쓰면 같은 값으로 두 번 만들 때 trap 합니다.
2. **`connect()` 가 반환해도 아직 `ready` 가 아닙니다.** 그 전에 read · write · subscribe 를 부르면 `NOT_READY` 로 실패합니다.
3. **스트림은 명령보다 먼저 엽니다.** `scanResults` 는 `startScan` 전에, `notifications(for:)` 는 `subscribe` 전에 얻어야 첫 값을 놓치지 않습니다.
