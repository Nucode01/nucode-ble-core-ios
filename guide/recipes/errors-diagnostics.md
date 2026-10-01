# 레시피: 실패 처리 · 이벤트 · 스냅샷

## 실패를 사용자 문구로 바꾸기

<!-- snippet: failure-message -->
```swift
/// 명령이 던진 오류를 사용자 문구로 바꾼다. 분기는 `failure.code` 로 한다(message 는 사람용이라 바뀔 수 있다)
func userMessage(for error: any Error) -> String {
    if error is CancellationError { return "취소됨" }
    guard let failure = (error as? BLEError)?.failure else { return "알 수 없는 오류" }
    switch failure.code {
    case .adapterUnavailable:
        return "블루투스를 켜 주세요"
    case .permissionDenied:
        return "블루투스 권한이 필요합니다"
    case .bleUnsupported:
        return "이 기기는 BLE 를 지원하지 않습니다"
    case .peripheralNotFound:
        return "기기를 찾지 못했습니다. 기기가 켜져 있고 가까이 있는지 확인해 주세요"
    case .notReady, .notConnected:
        return "기기가 아직 준비되지 않았습니다"
    case .operationTimeout:
        return "기기가 응답하지 않습니다"
    case .payloadTooLarge:
        return "보낼 데이터가 너무 큽니다"
    case .characteristicNotFound:
        return "이 기기가 지원하지 않는 기능입니다"
    default:
        return "BLE 오류 (\(failure.code.value))"
    }
}
```

- 분기는 `failure.code` 로 합니다. `message` 는 개발자용 설명이라 버전마다 바뀔 수 있습니다.
- `FailureCode` 는 enum 이 아니므로 `default` 가 꼭 있어야 합니다. 새 버전이 코드를 더해도 앱은 그대로 컴파일됩니다.
- 로그 · 서버에는 `failure.code.value`(예: `"NOT_READY"`)를 남기세요. Android 판과 같은 문자열이라 두 플랫폼 로그를 같이 볼 수 있습니다.

## 다시 해 볼지 판단하기

<!-- snippet: retryability -->
```swift
/// 같은 명령을 다시 불러도 되는가. 코드마다 기본값이 있고 원인에 따라 실패마다 다를 수 있다
func nextStep(for failure: BLEFailure) -> String {
    switch failure.retryability {
    case .never: return "고쳐야 한다(참조·크기·옵션이 틀렸다). 다시 불러도 같다"
    case .afterEnvironmentChange: return "블루투스·권한이 바뀌면 다시 한다(adapterStates 를 본다)"
    case .newConnectionMayHelp: return "끊고 다시 연결한 뒤 다시 한다"
    case .transientMayHelp: return "잠시 뒤 그대로 다시 한다"
    case .unknown: return "원인을 모른다. 한 번은 다시 해 볼 만하다"
    }
}
```

`retryability` 는 코드마다 기본값이 있고 원인에 따라 실패마다 다를 수 있습니다.
예: `LINK_FAILED` 는 보통 `.unknown` 이지만 기기가 페어링 정보를 지운 경우(`peerRemovedPairingInformation`)는 `.afterEnvironmentChange` 입니다
(사용자가 설정 앱의 블루투스 목록에서 기기를 지워야 풀립니다).

## 코드표

iOS 가 내는 코드입니다. "어떻게 오나"의 **던짐**은 명령이 `throw`, **상태**는 `connectionStates`/`scanStates` 의 실패, **이벤트**는 `client.events` 입니다.

| 코드 | 뜻 | 기본 retryability | 어떻게 오나 |
|---|---|---|---|
| `ADAPTER_UNAVAILABLE` | 블루투스 꺼짐 · 재시작 중 · 상태를 2초 안에 알 수 없음, 또는 연결 중 블루투스가 꺼짐 | afterEnvironmentChange | 던짐 · 상태 |
| `PERMISSION_DENIED` | 권한 없음(거부 · 제한 · Info.plist 문구 없음) | afterEnvironmentChange | 던짐 · 상태 |
| `BLE_UNSUPPORTED` | BLE 없음 | never | 던짐 |
| `SCAN_ALREADY_RUNNING` | 다른 조건의 스캔이 이미 도는 중 | never | 던짐 |
| `SCAN_STOPPED_BY_ADAPTER` | 스캔 중 블루투스 꺼짐 · 권한 상실 | afterEnvironmentChange | 상태(`scanStates`) |
| `PERIPHERAL_NOT_FOUND` | 저장된 ID 의 기기를 찾지 못함 | transientMayHelp | 던짐 |
| `CONNECT_DURING_DISCONNECT` | 해제 정리 중에 `connect()` | transientMayHelp | 던짐 |
| `CONNECTION_OPTIONS_CONFLICT` | 진행 중 연결과 다른 옵션으로 `connect()` | never | 던짐 |
| `LINK_FAILED` | 링크 실패 · 끊김 | unknown | 상태 |
| `LINK_TIMEOUT` | `autoReconnect: false` 연결이 15초 안에 안 붙음 | newConnectionMayHelp | 상태 |
| `SERVICE_DISCOVERY_START_FAILED` · `SERVICE_DISCOVERY_FAILED` | 서비스 탐색 실패(서비스 0개 포함) | unknown | 상태 |
| `SERVICE_DISCOVERY_TIMEOUT` | 탐색이 10초 안에 안 끝남 | newConnectionMayHelp | 상태 |
| `CONFIGURATION_TIMEOUT` | 구독 복원이 10초 안에 안 끝남 | newConnectionMayHelp | 상태 |
| `NOT_READY` | 세션이 `ready` 가 아님(연결 중 · `recovering` · 끊김 · 링크 유실 직후 1초 포함) | newConnectionMayHelp | 던짐 |
| `NOT_CONNECTED` | 받아들인 작업이 시작하려는 순간 연결이 없음(iOS 에서는 방어용으로만 남아 있어 보통 나지 않습니다) | newConnectionMayHelp | 던짐 |
| `CHARACTERISTIC_NOT_FOUND` | 탐색 결과에 없는 참조 | never | 던짐 · 이벤트 |
| `GATT_STATUS_FAILED` | 기기가 작업을 거절 · 실패(권한 · 암호화 부족은 afterEnvironmentChange) | unknown | 던짐 · 이벤트(구독 복원) |
| `OPERATION_TIMEOUT` | 작업이 5초 안에 안 끝남. **연결도 끊습니다** | newConnectionMayHelp | 던짐 |
| `OPERATION_INVALIDATED` | 대기 · 진행 중 작업이 해제 · 끊김으로 끝남 | newConnectionMayHelp | 던짐 |
| `PAYLOAD_TOO_LARGE` | 나누기 끔 · 고정 크기가 한 번 최대 크기를 넘음. 아무것도 안 보냄 | never | 던짐 |
| `CLIENT_CLOSED` | 닫힌 client, 또는 `close()` 가 대기 중 명령을 끝냄(세션 상태는 실패가 아니라 `.disconnected(.clientClosed)`) | never | 던짐 |
| `DISCONNECT_CLEANUP_TIMEOUT` · `DUPLICATE_CHARACTERISTIC_REFERENCE` · `GATT_OPERATION_CALLBACK_MISMATCH` · `GATT_OPERATION_DUPLICATE_CALLBACK` · `CLEANUP_FAILURE` · `INTERNAL_TRANSPORT_ERROR` | 진단용. 앱이 분기할 일은 거의 없습니다. `INTERNAL_TRANSPORT_ERROR` 는 라이브러리 결함이니 알려 주세요 | — | 이벤트 |

Android 전용 코드(`SCAN_START_THROTTLED` 등)는 iOS 에서 나지 않고 상수도 없습니다. `UNKNOWN_DEVICE` 는 상수가 있지만 iOS 에서는 나는 경로가 없습니다
(`session(for:)` 가 어떤 ID 에도 세션을 만들기 때문입니다).

## CoreBluetooth 원래 오류 보기

<!-- snippet: platform-detail -->
```swift
// CoreBluetooth 원래 오류가 있으면 보존된다(로그·문의용). 분기에는 쓰지 않는다
if let ios = failure.platformDetail?.ios {
    print("\(failure.code.value) ← \(ios.domain) \(ios.code) \(ios.symbolicName ?? "")")
}
```

`domain` 은 `CBErrorDomain` · `CBATTErrorDomain` 등, `code` 는 그 도메인의 값입니다. 문의 · 버그 보고에 붙여 주세요.

## 이벤트 로그

**언제 쓰나.** 모든 기기의 연결 흐름을 한 곳에서 기록할 때(디버그 화면 · 로그 파일 · 분석).

<!-- snippet: events -->
```swift
// 모든 기기의 연결 전이 · 탐색 결과 · 구독 복원 실패 · 진단이 한 줄로 온다(로그·분석용)
Task {
    for await event in client.events {
        switch event {
        case .connection(let id, let state):
            print("[link] \(id.rawValue.prefix(8)) \(state)")
        case .services(let id, let services):
            print("[gatt] \(id.rawValue.prefix(8)) services=\(services.count)")
        case .subscriptionRestoreFailed(let id, let characteristic, let failure):
            // 재연결 뒤 구독을 되살리지 못했다. 세션은 Ready 로 가지만 이 알림은 오지 않는다
            print("[gatt] \(id.rawValue.prefix(8)) restore \(characteristic.uuid) failed \(failure.code.value)")
        case .diagnostic(let code, let message):
            print("[diag] \(code.value) \(message)")
        }
    }
}
```

- `events` 는 구독한 뒤의 것만 받습니다. 앱 시작 직후부터 기록하려면 `start()` 전에 구독하세요.
- 화면 상태는 이벤트가 아니라 세션의 상태 스트림으로 그리세요. 이벤트는 받는 쪽이 느리면 오래된 것부터 버립니다.
- `.diagnostic` 은 앱 동작을 바꿀 신호가 아닙니다. 늦게 온 콜백, 해제 정리 시간 초과처럼 "라이브러리가 처리했지만 기록해 둘 만한 것"입니다.

## 스냅샷

<!-- snippet: snapshot -->
```swift
// 지금 상태를 한 번에 읽는다. 화면을 새로 열 때 스트림의 첫 값을 기다리지 않고 그릴 때 쓴다
let snapshot = await client.snapshot()
print("adapter:", snapshot.adapter, "scanning:", snapshot.scanning)
for session in snapshot.sessions {
    // subscriptions 는 구독 의도(앱이 켜 둔 것)다. 지금 켜져 있는지는 activeSubscriptions 가 알려 준다
    print(session.peripheralID.rawValue, session.state, session.subscriptions.count)
}
```

- 스트림은 구독하면 현재 값을 먼저 주므로 대부분 스냅샷이 필요 없습니다. 여러 기기의 상태를 한 번에 그릴 때 편합니다.
- `close()` 뒤에는 닫힌 순간의 스냅샷을 계속 돌려줍니다.
