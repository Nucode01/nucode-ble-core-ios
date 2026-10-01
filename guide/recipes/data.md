# 레시피: 읽기 · 쓰기 · 구독

모든 명령은 세션이 `ready` 일 때만 받습니다. 그 밖에는 `NOT_READY` 입니다(블루투스가 꺼져 있으면 `ADAPTER_UNAVAILABLE`).
한 세션의 명령은 부른 순서대로 하나씩 실행되므로 여러 Task 에서 동시에 불러도 섞이지 않습니다.

## read

<!-- snippet: read -->
```swift
let value = try await session.read(Battery.level)
let percent = value.first.map(Int.init) ?? 0
print("battery \(percent)%")
```

- 5초 안에 응답이 없으면 `OPERATION_TIMEOUT` 이고, **연결도 끊깁니다**(응답 없는 기기에 줄이 막히는 것을 막으려는 것입니다).
- 읽기 권한이 없는 characteristic 이면 기기가 거절해 `GATT_STATUS_FAILED` 입니다. 라이브러리는 properties 를 미리 검사하지 않습니다.
- 암호화가 필요한 characteristic 을 처음 읽으면 iOS 가 페어링 팝업을 띄웁니다. 사용자가 거절하면 `GATT_STATUS_FAILED`(`platformDetail` 에 원인)입니다.
- **구독 중인 characteristic 을 read 하면 조심하세요.** iOS 는 read 응답과 알림을 같은 콜백으로 줍니다. read 결과가 그 사이 온 알림 값일 수 있고,
  read 응답이 `notifications(for:)` 로도 한 번 더 옵니다. 확인용으로 읽을 값은 구독하지 않는 characteristic 에 두세요.

## write

<!-- snippet: write -->
```swift
// 기본값: 응답 있는 쓰기(.withResponse) + 자동 나누기(.automatic)
let receipt = try await session.write(NUS.rx, value: Data("ping".utf8), options: WriteOptions())
// receipt.delivery == .remoteAcknowledged: 기기가 받았다고 확인했다

// 긴 값도 그대로 넘긴다. 한 번에 보낼 수 있는 크기로 잘라 연달아 보낸다
let firmwareBlock = Data(repeating: 0xAB, count: 600)
let long = try await session.write(NUS.rx, value: firmwareBlock, options: WriteOptions())
print(long.bytesCompleted, "bytes in", long.chunksCompleted, "chunks")

// 응답 없는 쓰기: 빠르지만 기기가 받았는지는 모른다(.submittedToPlatform)
let fast = try await session.write(
    NUS.rx,
    value: Data(repeating: 0x00, count: 2000),
    options: WriteOptions(mode: .withoutResponse)
)

// 기기 프로토콜이 20바이트 조각을 요구하면 크기를 고정한다
let fixed = try await session.write(NUS.rx, value: firmwareBlock, options: WriteOptions(chunking: .fixed(20)))

// 나누면 안 되는 명령: 한 번에 못 보내는 크기면 아무것도 보내지 않고 PAYLOAD_TOO_LARGE
let atomic = try await session.write(NUS.rx, value: Data([0x01, 0x02]), options: WriteOptions(chunking: .disabled))
```

| `WriteOptions` | 동작 | `WriteReceipt.delivery` |
|---|---|---|
| `mode: .withResponse`(기본) | 조각마다 기기의 확인을 기다립니다 | `.remoteAcknowledged` |
| `mode: .withoutResponse` | iOS 가 받을 수 있을 때마다 보냅니다. 흐름 제어는 라이브러리가 합니다 | `.submittedToPlatform`(기기 도착은 모름) |
| `chunking: .automatic`(기본) | iOS 가 알려 준 한 번 최대 크기로 자릅니다 | |
| `chunking: .fixed(n)` | n 바이트로 자릅니다. n 이 최대 크기보다 크면 `PAYLOAD_TOO_LARGE` | |
| `chunking: .disabled` | 자르지 않습니다. 최대 크기보다 크면 `PAYLOAD_TOO_LARGE` | |

- 한 write 의 조각은 **끊기지 않고 연달아** 나갑니다. 다른 명령이 사이에 끼지 않습니다.
- `PAYLOAD_TOO_LARGE` 면 아무것도 보내지 않은 것입니다.
- 도중에 실패하면(끊김 · 기기 거절 · 시간 초과) 던지고, 일부 조각은 이미 갔을 수 있습니다. 다시 보낼지는 기기 프로토콜이 정합니다.
- 5초 제한은 조각마다 다시 셉니다. 큰 값도 조각이 계속 나가는 한 시간 초과가 나지 않습니다.
- 한 번 최대 크기는 연결마다 iOS 가 협상합니다(대개 응답 있는 쓰기 512바이트, 응답 없는 쓰기는 MTU-3). 앱이 지정할 수 없습니다.

## 알림(notify · indicate) 받기

<!-- snippet: subscribe -->
```swift
// 1. 받을 곳을 먼저 연다. 이 호출 뒤에 온 값은 놓치지 않는다
let values = session.notifications(for: NUS.tx)
// 2. 구독: 기기가 CCCD 를 받아들이면 반환한다
try await session.subscribe(NUS.tx)
// 3. 받기. 같은 characteristic 에 여러 곳이 notifications(for:) 를 열면 모두 같은 값을 받는다
let reader = Task {
    for await value in values {
        print("notify", String(decoding: value, as: UTF8.self))
    }
}

// 그만 받을 때: unsubscribe 는 멱등이고 재연결 때 되살리지 않는다
try await session.unsubscribe(NUS.tx)
reader.cancel() // 스트림을 닫는 것은 수신 쪽의 몫이다. 구독 자체는 unsubscribe 로만 끝난다
```

- `subscribe` 는 기기가 CCCD 쓰기를 받아들이면 반환합니다. 이미 구독 중이어도 다시 쓰고 성공합니다.
- **구독 의도는 연결보다 오래 삽니다.** 끊겼다 다시 연결되면 `ready` 전에 라이브러리가 다시 켭니다. 그래서 재연결 뒤 앱이 다시 `subscribe` 할 필요가 없습니다.
  다시 켜지 못하면 `client.events` 에 `.subscriptionRestoreFailed` 가 오고, 세션은 그래도 `ready` 로 갑니다.
- `notifications(for:)` 스트림은 연결이 끊겨도 끝나지 않습니다. 재연결 뒤의 알림도 같은 스트림으로 옵니다.
- `unsubscribe` 는 의도를 먼저 지우고 CCCD 끄기는 최선만 다합니다(실패해도 던지지 않습니다). 닫힌 client 에서만 `CLIENT_CLOSED` 를 던집니다.
- indicate 도 같은 API 입니다. iOS 는 앱이 값을 처리하기 **전에** 기기에 확인을 보내므로, indicate 가 "앱이 받았다"를 보장하지 않습니다.

## 요청-응답

**언제 쓰나.** 명령을 write 로 보내고 결과를 notify 로 받는 기기(NUS 류).

<!-- snippet: request-response -->
```swift
struct ResponseTimeout: Error {}

/// 명령을 쓰고 알림으로 오는 첫 응답을 기다린다. `NUS.tx` 는 미리 구독해 둔 상태를 전제한다
func request(_ command: Data, over session: any BLESession, timeout: Duration = .seconds(3)) async throws -> Data {
    let replies = session.notifications(for: NUS.tx) // 쓰기 전에 연다: 응답이 쓰기 완료보다 먼저 올 수 있다
    _ = try await session.write(NUS.rx, value: command, options: WriteOptions())
    return try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            for await reply in replies { return reply }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ResponseTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
```

- 응답 스트림은 **write 전에** 엽니다. 기기가 write 확인보다 응답을 먼저 보낼 수 있습니다.
- 여러 요청을 동시에 보내면 응답이 어느 요청의 것인지 알 수 없습니다. 기기 프로토콜에 요청 ID 가 없다면 요청을 한 번에 하나씩 보내세요(앱 쪽 actor 로 직렬화).

## 지금 켜져 있는 구독 보기

<!-- snippet: active-subscriptions -->
```swift
// 이 연결에서 기기가 실제로 켜 준 구독. 연결이 끊기면 빈 집합, 재연결 뒤 복원되면 다시 채워진다
Task {
    for await active in session.activeSubscriptions {
        print("notify on:", active.contains(NUS.tx))
    }
}
```

`activeSubscriptions` 는 **이 연결에서 기기가 실제로 켜 준 것**입니다. 앱이 원한 것(구독 의도)은 `snapshot().sessions[…].subscriptions` 입니다.
재연결 직후 두 집합이 다르면 복원이 아직 안 됐거나 실패한 것입니다.
