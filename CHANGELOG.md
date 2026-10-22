# Changelog

## 미출시

### Breaking changes

- `BLESession.readDescriptor(_:)`·`BLESession.writeDescriptor(_:_:)` 가 생겼다(CANDIDATE-32). Android `BleSession.readDescriptor`·`writeDescriptor` 와 같은 뜻이다.
  - **fake session 작성자 영향**: `BLESession` 을 직접 구현한 가짜는 컴파일이 깨진다. 두 함수를 더한다.
  - 저장소 안 예: `Samples/Demo/Tests` 의 `FakeSession`. Demo 가 0.2.2 고정을 풀 때 깨진다.

```swift
func readDescriptor(_ descriptor: DescriptorRef) async throws -> Data { Data() }
func writeDescriptor(_ descriptor: DescriptorRef, _ value: Data) async throws {}
```

### Added

- `DescriptorRef(characteristic:uuid:instanceIndex:)`(기본 0)와 `GATTCharacteristic.descriptors`(탐색 순서). Ready 시점의 `services` 에는 descriptor 가 채워져 있다.
  - `GATTCharacteristic(ref:properties:)` 는 그대로 컴파일된다(`descriptors` 기본값 `[]`).
  - iOS 는 characteristic 마다 `discoverDescriptors(for:)` 를 불러 Ready 가 그만큼 늦어진다. descriptor 탐색이 실패하면 `SERVICE_DISCOVERY_FAILED` 다.
- descriptor read · write 는 characteristic read · write 와 같은 큐 · 기한 · 끊김 규칙과 진입 검사 순서를 따른다(contract/states.md §5).
  - 탐색 결과에 없는 참조는 `CHARACTERISTIC_NOT_FOUND` 다.
  - write 는 응답 있는 쓰기 한 번이고 나누지 않는다. 512바이트를 넘으면 `PAYLOAD_TOO_LARGE` 다.
- 실패 코드 `DESCRIPTOR_WRITE_NOT_ALLOWED`(`attribute`, `never`, iOS 전용): CCCD(0x2902)에 `writeDescriptor` 하면 플랫폼 호출 전에 던진다.
  구독 상태는 바뀌지 않는다. iOS 는 CCCD 를 `subscribe`·`unsubscribe` 로만 바꾼다(Android 는 CCCD 쓰기를 받는다).
- 값은 원본 bytes 다. `CBDescriptor.value` 의 숫자(0x2900·0x2902·0x2903)는 2바이트 little-endian, 문자열(0x2901)은 UTF-8 로 다시 인코딩한다.
  기기가 0x2901 에 UTF-8 이 아닌 bytes 를 넣었으면 원본을 잃는다(iOS 한계).
- 계약 시나리오: sim 46개 PASS. descriptor 4개(`descriptors-discovered`·`descriptor-read-write`·`descriptor-read-during-link-loss`·`descriptor-cccd-write-rejected`)를 포함한다.
  실기기 실행은 아직 하지 않았다.

## 0.4.0 (2026-10-22)

### Breaking changes

- `BLESession` 에 `writeLimits: AsyncStream<WriteLimits?>` 가 생겼다(CANDIDATE-5). Android `BleSession.writeLimits` 와 같은 뜻이다.
  - 값은 방식별로 코어가 write 를 나눌 때 쓰는 최대 바이트다(`WriteLimits.withResponse` · `withoutResponse`). 자동 나누기의 조각 크기와 `.disabled` · `.fixed` 의 한도가 이 값이다.
  - Ready 게시 직전에 정해 연결 동안 바꾸지 않는다. Ready 를 떠나면(Disconnecting · Recovering · Disconnected) `nil` 이다. client 를 닫아도 `nil` 로 끝난다.
  - **fake session 작성자 영향**: `BLESession` 을 직접 구현한 가짜는 컴파일이 깨진다(저장소 안 예: `Samples/Demo/Tests` 의 `FakeSession`, Demo 가 0.2.2 고정을 풀 때). 프로퍼티를 더한다.

```swift
var writeLimits: AsyncStream<WriteLimits?> {
    AsyncStream { $0.yield(WriteLimits(withResponse: 182, withoutResponse: 182)) }
}
```

## 0.3.0 (2026-10-12)

### Breaking changes

- `BLEClient` 가 클래스에서 protocol(`public protocol BLEClient: AnyObject, Sendable`)로 바뀌었다. 계약 문서 api-contract §BLEClient 와 Android `BleClient` 와 같은 모양이다.
  - 생성은 `BLEClientFactory.make(options:)` 로 하고, 보관 타입은 `any BLEClient` 다. 구현 클래스(`DefaultBLEClient`)는 공개하지 않는다.
  - 같은 복원 identifier 로 프로세스 안에서 두 번 만들면 trap 하는 것은 이전과 같다(이제 factory 가 점유한다).
  - 동작은 같다(`swift test`, 계약 시나리오 sim 39개 PASS). d4aaf8e 뒤 iPhone XR 실기기 계약 실행에서 시나리오 24개가 모두 PASS 했다.

```swift
// 이전
let client = BLEClient()
let restoring = BLEClient(options: options)
// 이후
let client: any BLEClient = BLEClientFactory.make()
let restoring: any BLEClient = BLEClientFactory.make(options: options)
```

- 앱 시험에서 client 를 가짜로 바꿔 끼울 수 있다. `guide/recipes/app-integration.md` 레시피 "시험에서 client 바꿔 끼우기" 참고.

- `GATTCharacteristic` 에 `properties: Set<CharacteristicProperty>` 가 생겼다(CANDIDATE-30). Android `GattCharacteristic.properties` 와 같은 5종(`read`·`writeWithResponse`·`writeWithoutResponse`·`notify`·`indicate`)이다.
  - `init(ref:)` 를 없앴다. `init(ref:properties:)` 만 있다. 빈 집합 기본값은 "모름"과 "없음"을 가리지 못해서 두지 않는다.
  - **fake client 작성자 영향**: 앱 시험의 가짜 client 가 `GATTCharacteristic(ref:)` 로 만들었다면 컴파일이 깨진다. `properties:` 를 넘긴다.
  - `properties` 도 `Hashable` 비교 대상이다. ref 가 같아도 properties 가 다르면 다른 값이다.
  - 정보 제공용이다. 코어는 이 값으로 read·write·subscribe 를 거르지 않는다(잘못 광고하는 기기가 있다). 거르기는 앱이 한다.
  - iOS GATT 캐시가 옛 properties 를 돌려줄 수 있다(알려진 한계).

```swift
// 이전
GATTCharacteristic(ref: ref)
// 이후
GATTCharacteristic(ref: ref, properties: [.read, .notify])
```

## 0.2.2 (2026-10-01)

공개 API 는 0.2.0 과 같다(`swift package diagnose-api-breaking-changes 0.2.0`). 실패 코드 값의 뜻이 바뀐다.

### Breaking changes (코드 뜻)

- read·write·subscribe 의 진입 검사를 Android 와 같은 순서로 맞췄다(contract/states.md §5 명령 진입 검사 순서):
  닫힘 `CLIENT_CLOSED` → 어댑터(`ADAPTER_UNAVAILABLE`·`PERMISSION_DENIED`·`BLE_UNSUPPORTED`, `.unknown` 이면 connect 와 같이 최대 2000ms 판정 대기)
  → 세션이 Ready 아님 `NOT_READY` → 참조 없음 `CHARACTERISTIC_NOT_FOUND`.
  - 연결 전·`Disconnected`·`Disconnecting`·`Recovering`, 링크 유실 뒤 원인 확정 창(1000ms, 공개 상태는 아직 `Ready`)에서 이전에는
    `NOT_CONNECTED` 였고 이제 `NOT_READY` 다.
  - 블루투스가 꺼진 뒤의 명령은 이전에는 `NOT_CONNECTED` 였고 이제 `ADAPTER_UNAVAILABLE` 이다.
  - `NOT_CONNECTED` 로 분기하던 앱은 `NOT_READY`(연결 문제)와 `ADAPTER_UNAVAILABLE`(환경)로 옮긴다. `NOT_CONNECTED` 는 진입 검사에서 더 나지 않는다.
  - unsubscribe 는 그대로다(닫힘만 거절하고 의도를 먼저 지우는 best-effort).
- `Samples/ManualTest` 점검 2 는 꺼진 채 read 도 `ADAPTER_UNAVAILABLE` 만 통과로 본다.

### Documentation

- `guide/`: 개발자 가이드(설치·개념·레시피·문제 해결). 예시는 `guide/Snippets` 패키지로 컴파일을 확인하고 `guide/check_snippets.py` 로 문서와 대조한다.

## 0.2.1 (2026-09-30)

공개 API 는 0.2.0 과 같다(`swift package diagnose-api-breaking-changes 0.2.0`, `package` 선언 1건은 `api-breakage-allowlist.txt`).
계약 시나리오 36개(sim), 실기기 두 대 기록 비교 23개 일치, iPhone XR 수동 시험 체크리스트 9개(블루투스 끄고 켜기·비행기 모드·재부팅·상태 복원 포함)를
`Samples/ManualTest/auto/run-checklist.sh` 로 확인했다.

### Fixes

- Ready 이후 링크가 끊긴 직후 블루투스를 끄면 재연결 대기가 실패로 끝나 `Disconnected(Failed:LINK_FAILED)` 가 되고, 블루투스를 다시 켜도
  autoReconnect 세션이 다시 연결하지 않던 문제를 고쳤다. 링크 유실이나 재연결 대기 실패 뒤 1000ms 안에 어댑터가 꺼지면 `ADAPTER_UNAVAILABLE` 로 끝나고
  어댑터가 돌아올 때 한 번 다시 연결한다. 진짜 링크 실패는 최대 1000ms 늦게 알려진다.
- 블루투스가 꺼진 동안 `connect()` 를 부르면 어댑터 복귀 때의 재연결 예약이 지워지던 문제를 고쳤다.
- 상태 복원으로 돌려받은 미등록 기기의 연결을 poweredOn 전에 끊으려다 무시되어, 세션 없는 연결이 기기를 붙잡고 스캔에 보이지 않던 문제를 고쳤다.
  이제 첫 poweredOn 에서 끊는다.

### Internal

- 연결 상태 전이, GATT 큐 규칙, 스캔 수명, 어댑터 판정을 순수 Core 로 옮기고, Ports 와 Driver 를 나누고, 구체 드라이버 생성은 Factory(공개 init)에서만 한다.
  시간은 `BLEClock` 포트로만 쓴다. 이 구조는 `ArchitectureRulesTests` 가 지킨다.
- `Samples/ManualTest`: DDD 구조의 수동 시험 앱과 체크리스트 자동 판정·실기기 자동 실행.

## 0.2.0 (2026-09-30)

첫 릴리스. Android 0.2.0 과 같은 계약(nucode-ble-core `contract/`)을 따르는 CoreBluetooth 구현.
iOS 17, `@BLECoreActor` 격리, 상태 복원(`BLEOptions.restoreIdentifier`, `register`) 지원. 블루투스 켜고 끄기·재부팅 수동 시험은 하지 않고 태그했다.
