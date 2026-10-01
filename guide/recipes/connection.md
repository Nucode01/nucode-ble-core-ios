# 레시피: 연결 유지 · 여러 기기

## 끊겨도 다시 붙는 연결

**언제 쓰나.** 기기가 잠깐 멀어지거나 꺼졌다 켜져도 앱이 다시 붙어 있어야 할 때(웨어러블 · 센서 · 차량 기기).

<!-- snippet: auto-reconnect -->
```swift
/// 끊겨도 다시 붙는 연결. autoReconnect 연결에는 링크 기한이 없어 기기가 멀리 있으면 무한히 기다린다
func keepConnected(_ client: BLEClient, _ id: PeripheralID) async throws -> any BLESession {
    let session = try await client.connect(id, options: ConnectOptions(autoReconnect: true))
    do {
        try await waitUntilReady(session, timeout: .seconds(60)) // 첫 연결의 기한은 앱이 정한다
    } catch {
        await session.disconnect() // 포기하면 OS 대기 연결도 거둔다
        throw error
    }
    try await session.subscribe(NUS.tx) // 한 번 켜 두면 재연결 때마다 Ready 전에 자동으로 다시 켜진다
    return session
}
```

`autoReconnect: true` 가 하는 일:

| 상황 | 동작 |
|---|---|
| `ready` 뒤 링크가 끊김 | `recovering(lastFailure:)` 로 가고 iOS 에 대기 연결을 겁니다. 기기가 다시 보이면 iOS 가 붙이고 `connecting → … → ready` 로 돌아옵니다 |
| 앱이 백그라운드 · 일시정지 | 대기 연결은 iOS 가 들고 있으므로 계속 유효합니다(`bluetooth-central` 필요) |
| 블루투스를 끔 | `disconnected(.failed(ADAPTER_UNAVAILABLE))` 로 끝납니다 |
| 블루투스를 다시 켬 | **한 번** 다시 연결합니다 |
| 켜 둔 구독 | 재연결마다 `ready` 전에 다시 켭니다 |
| 첫 연결의 기한 | **없습니다.** 기기가 없으면 `connecting` 에서 계속 기다립니다 |

`autoReconnect: false` 는 끊기면 `disconnected(.failed(…))` 로 끝나고, 다시 붙이는 것은 앱의 몫입니다([재시도](scan-connect.md#실패하면-다시-시도하기)).

## 복구 상태를 보여 주고 너무 오래 걸리면 포기하기

<!-- snippet: recovering-watch -->
```swift
/// 연결 상태를 따라가며 화면 문구를 정하고, 복구가 너무 오래 걸리면 포기한다
func watchConnection(_ session: any BLESession, giveUpAfter limit: Duration = .seconds(300)) -> Task<Void, Never> {
    Task {
        var giveUp: Task<Void, Never>?
        for await state in session.connectionStates {
            giveUp?.cancel()
            giveUp = nil
            switch state {
            case .ready:
                print("연결됨")
            case .recovering(let lastFailure):
                print("다시 연결하는 중:", lastFailure.code.value)
                giveUp = Task {
                    try? await Task.sleep(for: limit)
                    guard !Task.isCancelled else { return }
                    await session.disconnect() // Recovering 에는 기한이 없다. 앱이 포기 시점을 정한다
                }
            case .disconnected(reason: .failed(let failure)) where failure.code == .adapterUnavailable:
                print("블루투스가 꺼졌다. 다시 켜지면 한 번 자동으로 연결한다")
            case .disconnected(reason: .failed(let failure)):
                print("끊김:", failure.code.value, failure.message)
            case .disconnected:
                print("연결 안 됨")
            case .connecting, .discoveringServices, .configuring:
                print("연결 중")
            case .disconnecting:
                print("해제 중")
            }
        }
    }
}
```

- `recovering` 에는 기한이 없습니다. 무한히 기다리는 것이 싫으면 앱이 시간을 재서 `disconnect()` 합니다.
- `disconnect()` 는 멱등입니다. 이미 끊겼으면 아무 일도 없고, 해제 중이면 같은 정리를 기다립니다. 정리가 끝나면 반환합니다.
- `disconnect()` 한 뒤에는 자동 재연결도 멈춥니다. 다시 붙이려면 `connect()` 를 부릅니다.

## 블루투스를 끄고 켤 때

| 순간 | 세션 | 명령 | 스캔 |
|---|---|---|---|
| 끔 | `disconnected(.failed(ADAPTER_UNAVAILABLE))` (autoReconnect 세션은 잠깐 `recovering` 을 거칠 수 있습니다) | `ADAPTER_UNAVAILABLE` | `.failed(SCAN_STOPPED_BY_ADAPTER)` 로 끝남 |
| 꺼진 동안 `connect()` | 변화 없음 | `ADAPTER_UNAVAILABLE` 을 던짐. autoReconnect 세션의 "켜지면 다시 연결"은 지워지지 않습니다 | — |
| 켬 | autoReconnect 세션만 한 번 `connecting` | 정상 | 재개하지 않음. 앱이 다시 `startScan` |

비행기 모드도 블루투스를 끄면 같은 순서입니다.

## 여러 기기

<!-- snippet: multi-device -->
```swift
/// 기기마다 세션이 따로 있고 GATT 작업 줄도 따로다. 한 기기의 느린 작업이 다른 기기를 막지 않는다
func connectAll(_ client: BLEClient, _ ids: [PeripheralID]) async -> [PeripheralID: Result<any BLESession, any Error>] {
    await withTaskGroup(of: (PeripheralID, Result<any BLESession, any Error>).self) { group in
        for id in ids {
            group.addTask {
                do {
                    let session = try await client.connect(id, options: ConnectOptions(autoReconnect: true))
                    try await waitUntilReady(session)
                    return (id, .success(session))
                } catch {
                    return (id, .failure(error))
                }
            }
        }
        var outcome: [PeripheralID: Result<any BLESession, any Error>] = [:]
        for await (id, result) in group { outcome[id] = result }
        return outcome
    }
}

/// 연결된 모든 기기에 같은 명령을 동시에 보낸다
func broadcast(_ command: Data, to sessions: [any BLESession]) async {
    await withTaskGroup(of: Void.self) { group in
        for session in sessions {
            group.addTask { _ = try? await session.write(NUS.rx, value: command, options: WriteOptions()) }
        }
    }
}
```

- 기기마다 세션 · 상태 · 작업 줄이 따로입니다. 한 기기의 느린 read 가 다른 기기의 write 를 기다리게 하지 않습니다.
- 동시에 붙을 수 있는 기기 수는 iOS 와 기기 쪽 제한을 따릅니다. 라이브러리는 제한을 두지 않습니다.
- 한 기기에 대한 명령끼리는 순서대로 실행되므로 한 기기에 병렬로 보내도 빨라지지 않습니다.

## 같은 기기의 세션을 다시 얻기

<!-- snippet: session-reuse -->
```swift
// 같은 ID 로 얻은 세션은 같은 연결을 본다. 화면마다 따로 얻어도 된다
let a = try client.session(for: id)
let b = try client.session(for: id)
// a.connectionStates 와 b.connectionStates 는 같은 값을 준다. 연결하지 않고 상태만 볼 때도 session(for:) 를 쓴다
```

세션을 오래 들고 있을 필요가 없습니다. 필요할 때마다 `client.session(for:)` 로 얻어도 같은 연결을 봅니다.
`disconnect()` 뒤에도 세션은 남아 있고, 같은 세션으로 다시 `connect()` 할 수 있습니다.

## 앱이 종료된 뒤에도 이어받기

시스템이 백그라운드에서 앱을 종료한 뒤에도 연결 · 알림을 이어받으려면 상태 복원을 씁니다. 시작 코드가 달라지므로
[앱 구조에 넣기 — 상태 복원](app-integration.md#상태-복원)에서 다룹니다.
