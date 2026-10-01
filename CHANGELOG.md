# Changelog

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
