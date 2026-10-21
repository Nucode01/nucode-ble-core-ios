# 3. 핵심 개념

## 3.1 `BLEClient` 와 `BLESession`

| | `BLEClient` | `BLESession` |
|---|---|---|
| 무엇 | 라이브러리 진입점. 앱당 하나 | 기기 하나를 보는 창 |
| 만드는 법 | `BLEClientFactory.make()` 또는 `BLEClientFactory.make(options: BLEOptions(restoreIdentifier:))` (구현 클래스는 패키지 밖에서 보이지 않습니다) | `try await client.connect(id, options:)` 또는 `try client.session(for: id)` |
| 하는 일 | 어댑터 상태, 스캔, 이벤트, 스냅샷, 복원 등록, 전체 종료 | 연결 · 해제, read · write, 구독, 기기별 상태 |
| 수명 | `close()` 하면 끝(되살릴 수 없음) | 가벼운 view. 같은 ID 로 여러 번 얻어도 같은 상태를 봅니다 |

- `client.connect(id, options:)` 는 `try client.session(for: id)` 로 세션을 얻고 `session.connect(options:)` 를 부른 것과 같습니다.
- `client.session(for:)` 는 연결하지 않고 세션만 얻습니다(`async` 가 아닙니다). 연결 전 상태 관찰, 이미 연결된 기기의 세션을 다시 얻을 때 씁니다.
  닫힌 client 에서만 `CLIENT_CLOSED` 를 던집니다.
- 한 번 쓴 ID 의 세션은 `close()` 전까지 client 에 남습니다(`snapshot().sessions` 에 보입니다).
- 두 타입 모두 `Sendable` 입니다. 어느 Task · actor 에서 불러도 됩니다.

## 3.2 `PeripheralID`

기기를 가리키는 불투명한 ID 입니다. iOS 에서는 **이 앱에게** 기기가 보이는 UUID 문자열(`CBPeripheral.identifier`)입니다.

- 스캔 결과의 `ScanResult.peripheralID` 를 그대로 쓰세요. 저장은 `rawValue`, 복원은 `PeripheralID(rawValue:)` 입니다.
- MAC 주소가 아닙니다. **같은 기기라도 앱마다, 폰마다 다른 값**이고 Android 의 ID 와도 다릅니다. 서버에 기기를 등록할 때는 기기가 알려 주는 일련번호 같은 값을 쓰세요.
- 저장된 ID 로 `connect()` 하면 라이브러리가 ① 시스템이 아는 기기 목록 ② 이미 연결된 기기 목록 ③ 짧은 스캔(3초) 순서로 찾습니다.
  못 찾으면 `PERIPHERAL_NOT_FOUND` 를 던집니다(`autoReconnect` 와 무관. iOS 는 본 적 없는 기기에 대기 연결을 걸 수 없습니다).
- 앱을 지웠다 다시 깔거나 기기 설정의 블루투스 목록에서 기기를 지우면 ID 가 바뀔 수 있습니다. 이때도 `PERIPHERAL_NOT_FOUND` 입니다. 다시 스캔하세요.

## 3.3 `BLEUUID` · `ServiceRef` · `CharacteristicRef`

```text
CharacteristicRef(
    service: ServiceRef(uuid: 서비스 UUID, instanceIndex: 0),  // 같은 UUID 서비스 중 몇 번째인가(탐색 순서, 0부터)
    uuid: characteristic UUID,
    instanceIndex: 0                                          // 그 서비스 안에서 같은 UUID characteristic 중 몇 번째인가
)
```

- `BLEUUID(string:)` 은 4자리(`"180F"`) · 8자리 짧은 형식과 36자 형식을 받고, 틀리면 `nil` 입니다. 짧은 형식은 Bluetooth base UUID 로 넓힙니다.
  `BLEUUID(rawValue: UUID)` 로도 만듭니다. 문자열 표기는 늘 소문자 128비트입니다.
- 대부분의 기기는 UUID 가 겹치지 않으므로 `instanceIndex` 는 0 입니다.
- 참조는 **값**입니다. 연결 전에 만들어 둘 수 있고(복원 등록에 필요), 연결이 바뀌어도 그대로 씁니다.
- 탐색 결과(`session.services`)에 없는 참조로 read · write · subscribe 하면 `CHARACTERISTIC_NOT_FOUND` 입니다.

## 3.4 `ConnectionState` 생애주기

```text
disconnected(.initial)
     │ connect()
     ▼
connecting ──► discoveringServices ──► configuring ──► ready
     │                 │                    │ (구독 복원)
     └──── 실패 · 시간 초과 ─────────────────┴──────────► disconnected(.failed(원인))

ready ── disconnect() ──► disconnecting ──► disconnected(.requested)
ready ── 링크 끊김 ──► autoReconnect: false → disconnected(.failed(LINK_FAILED))
                  └► autoReconnect: true  → recovering(lastFailure) ── OS 가 다시 붙이면 ──► connecting … ready
블루투스 꺼짐 ──► disconnected(.failed(ADAPTER_UNAVAILABLE))   (autoReconnect: true 면 다시 켜질 때 한 번 재연결)
client.close() ──► 끝나지 않은 세션은 disconnected(.clientClosed)
```

| 상태 | 뜻 |
|---|---|
| `.disconnected(reason:)` | 연결 없음. `reason` 은 `.initial`(아직 시도 전), `.requested`(앱이 `disconnect()`), `.clientClosed`(`close()`), `.failed(BLEFailure)`(실패로 끝남) |
| `.connecting` | 기기를 찾고 링크를 맺는 중 |
| `.discoveringServices` | 서비스 · characteristic 탐색 중 |
| `.configuring` | 구독 의도 복원 중(iOS 에는 MTU 단계가 없습니다) |
| `.ready` | read · write · subscribe 가능 |
| `.disconnecting` | 해제 정리 중 |
| `.recovering(lastFailure:)` | `autoReconnect: true` 세션의 링크가 끊겨 OS 재연결을 기다리는 중. **기한이 없습니다** — 포기하려면 `disconnect()` |

`ready` 는 "GATT 명령을 보낼 수 있다"는 뜻이지 기기 쪽 인증 · handshake 완료를 뜻하지 않습니다.

세부 규칙 세 가지:

- **`recovering` 은 한 번이라도 `ready` 였던 연결만 갑니다.** 첫 연결이 `ready` 전에 끊기면 `autoReconnect: true` 여도 `disconnected(.failed(…))` 로 끝납니다.
- **`autoReconnect: false` 세션이 `ready` 에서 링크를 잃으면 1초 동안 원인을 확정합니다.** 블루투스를 끄면 iOS 는 링크 끊김을 먼저, 꺼짐을 나중에 알려 주기 때문입니다.
  그 사이 블루투스 꺼짐이 확인되면 `LINK_FAILED` 가 아니라 `ADAPTER_UNAVAILABLE` 로 끝납니다. 그래서 진짜 링크 실패는 최대 1초 늦게 알려지고,
  그 1초 동안 상태는 아직 `ready` 로 보이지만 명령은 `NOT_READY` 입니다.
- **`recovering` 중 블루투스가 꺼지면** `disconnected(.failed(ADAPTER_UNAVAILABLE))` 로 끝나고, 다시 켜질 때 한 번 연결을 시도합니다.

## 3.5 `AdapterState`

| 값 | 뜻 | 앱이 할 일 |
|---|---|---|
| `.unknown` | 아직 모름(`start()` 전, 첫 콜백 전) | 기다림 |
| `.ready` | 쓸 수 있음 | — |
| `.poweredOff` | 블루투스 꺼짐 | 켜 달라고 안내 |
| `.resetting` | 블루투스 재시작 중 | 기다림 |
| `.unauthorized(canRequest: true)` | 아직 묻지 않음 | 설명 뒤 `start()`(팝업) |
| `.unauthorized(canRequest: false)` | 거부 · 제한, 또는 Info.plist 문구 없음 | 설정 앱으로 안내 / 앱 수정 |
| `.unsupported` | BLE 없음(시뮬레이터 등) | 기능 숨김 |

## 3.6 명령의 두 가지 결과 전달

| 언제 알 수 있나 | 어떻게 오나 | 예 |
|---|---|---|
| 명령을 부른 그 자리 | `throw BLEError` | 꺼진 블루투스, `ready` 가 아님, 없는 characteristic, 기기를 못 찾음, 옵션 충돌 |
| 나중에 | 상태 스트림 | 링크 실패, 탐색 실패, 시간 초과, 끊김 → `connectionStates` 의 `.disconnected(.failed(…))` · `.recovering(…)` |

`connect()` 가 대표적입니다. 정상 반환은 "시도가 시작됐다"는 뜻이고, 결과는 `connectionStates` 로 옵니다.
read · write · subscribe 는 결과가 나올 때까지 기다렸다가 값을 돌려주거나 던집니다.

## 3.7 실패: `BLEError` · `BLEFailure` · `FailureCode`

```text
BLEError                      ← throw 되는 타입
  └ failure: BLEFailure
       ├ code: FailureCode     ← 분기는 이것으로 (.notReady, .adapterUnavailable …)
       │    ├ value            "NOT_READY" — Android 와 같은 문자열
       │    └ category         environment · scan · connection · validation · operation · attribute
       ├ message               사람용 설명(바뀔 수 있음. 분기 금지)
       ├ retryability          .never · .afterEnvironmentChange · .newConnectionMayHelp · .transientMayHelp · .unknown
       └ platformDetail?.ios   CoreBluetooth 원래 오류(domain · code · symbolicName)
```

`FailureCode` 는 enum 이 아니라 값 타입이라 `switch` 에 `default` 가 필요합니다. 새 버전이 코드를 추가해도 앱이 깨지지 않게 하려는 것입니다.
코드 전체 표는 [실패 처리 레시피](recipes/errors-diagnostics.md#코드표)에 있습니다.

`Task` 가 취소되면 기다리던 명령은 `BLEError` 가 아니라 `CancellationError` 를 던집니다. 이미 기기로 보낸 작업은 멈추지 않고 끝까지 갑니다.

## 3.8 스트림과 스레드

| 스트림 | 종류 | 구독하면 |
|---|---|---|
| `client.adapterStates` · `client.scanStates` | 상태 | 현재 값을 먼저 받고, 이후 바뀔 때마다 받습니다. 값을 버리지 않습니다 |
| `session.connectionStates` · `session.services` · `session.activeSubscriptions` · `session.writeLimits` | 상태 | 같음 |
| `client.scanResults` · `client.events` · `session.notifications(for:)` | 이벤트 | 구독한 뒤에 생긴 것만 받습니다. 받는 쪽이 느려 256개가 쌓이면 오래된 것부터 버립니다 |

- 스트림은 **프로퍼티를 읽는 순간 구독이 등록됩니다**(동기). 그래서 명령 전에 얻어 두면 그 뒤의 값을 놓치지 않습니다.
- 여러 곳에서 같은 스트림을 얻으면 각자 같은 값을 받습니다.
- `for await` 를 돌던 Task 를 취소하면 그 구독만 끝납니다. 연결 · 구독 같은 라이브러리 상태는 바뀌지 않습니다.
- `close()` 하면 모든 스트림이 끝납니다(상태 스트림은 마지막 값을 준 뒤 끝납니다).
- 라이브러리 내부는 전용 직렬 큐 하나에서 돕니다. 스트림 값은 그 큐에서 나오므로 **UI 갱신은 `@MainActor` 에서** 하세요([SwiftUI 모델](recipes/app-integration.md#swiftui-모델)).

## 3.9 시간 제한

값은 바꿀 수 없습니다(Android 기본값과 같습니다).

| 단계 | 제한 | 넘기면 |
|---|---|---|
| 링크(`autoReconnect: false`) | 15초 | `LINK_TIMEOUT` |
| 링크(`autoReconnect: true`) | **없음** | 계속 기다림. 앱이 `disconnect()` 로 포기 |
| 저장된 ID 로 기기 찾기 스캔 | 3초 | `PERIPHERAL_NOT_FOUND`(throw) |
| 서비스 탐색 | 10초 | `SERVICE_DISCOVERY_TIMEOUT` |
| 설정(구독 복원) | 10초 | `CONFIGURATION_TIMEOUT` |
| GATT 작업 하나(write 는 조각마다) | 5초 | `OPERATION_TIMEOUT` — **연결도 끊습니다**(응답 없는 기기의 줄을 비우려는 것) |
| 해제 정리 | 5초 | 강제로 `disconnected` 로 끝내고 진단 이벤트 |
| 어댑터 상태 판정 대기(`.unknown`) | 2초 | `ADAPTER_UNAVAILABLE` |
