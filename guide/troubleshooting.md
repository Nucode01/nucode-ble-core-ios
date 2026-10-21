# 문제 해결과 한계

## 자주 틀리는 것

| 증상 | 원인 | 고치는 법 |
|---|---|---|
| `connect()` 뒤 바로 read 하면 `NOT_READY` | `connect()` 는 시도가 **시작되면** 반환합니다 | `connectionStates` 로 `.ready` 를 기다립니다([waitUntilReady](README.md#3-빠른-시작)) |
| 첫 알림 · 첫 스캔 결과를 놓침 | 명령 뒤에 스트림을 얻었습니다 | `notifications(for:)` 는 `subscribe` 전, `scanResults` 는 `startScan` 전에 얻습니다 |
| 화면을 다시 열 때마다 연결이 끊김 | 화면이 `BLEClient` 를 만들고 버립니다 | client 는 앱당 하나([client 소유](recipes/app-integration.md#client-는-누가-갖나)) |
| `restoreIdentifier` 로 만들 때 trap | 같은 값으로 두 번 만들었습니다(미리보기 · 테스트 · 화면 재생성) | 앱 수명 동안 하나. 미리보기에서는 `restoreIdentifier` 없이 만듭니다 |
| `register` 에서 trap | `start()` 뒤에 불렀습니다 | `start()` 전에 부릅니다 |
| `start()` 에서 trap | 복원 옵션인데 `UIBackgroundModes` 에 `bluetooth-central` 이 없습니다 | [Info.plist](install.md#22-infoplist) |
| 항상 `.unauthorized(canRequest: false)` | Info.plist 에 `NSBluetoothAlwaysUsageDescription` 이 없거나 사용자가 거부했습니다 | 키를 넣거나 설정 앱으로 안내합니다 |
| 시뮬레이터에서 아무것도 안 됨 | 시뮬레이터에는 블루투스가 없습니다 | 실기기에서 실행합니다 |
| 백그라운드에서 스캔 결과가 없음 | iOS 는 서비스 UUID 필터 없는 스캔을 백그라운드에서 멈춥니다 | `ScanFilter(serviceUUIDs:)` 를 씁니다 |
| `serviceUUIDs` 와 `manufacturerData` 를 함께 줬더니 일부 기기가 안 보임 | iOS 가 `serviceUUIDs` 로 먼저 거르므로, 그 서비스를 광고하지 않는 기기는 나온다고 보장하지 않습니다(iOS 한계) | `serviceUUIDs` 를 비우고 다른 항목만 줍니다(포그라운드 전용). [스캔 필터](recipes/scan-connect.md#스캔-필터) |
| 블루투스를 다시 켰는데 스캔이 안 돎 | 스캔은 자동으로 재개하지 않습니다 | `scanStates` 가 `.failed` 면 다시 `startScan` 합니다 |
| 같은 알림이 두 번 옴 | `onNotification` 과 `notifications(for:)` 를 둘 다 씁니다 | 한 곳에서만 셉니다 |
| read 결과가 이상한 값 | 구독 중인 characteristic 을 읽어 알림 값을 받았습니다 | [read 주의](recipes/data.md#read) |
| `OPERATION_TIMEOUT` 뒤 연결이 끊김 | 의도된 동작입니다. 응답 없는 기기의 작업 줄을 비웁니다 | autoReconnect 면 다시 붙습니다. 아니면 다시 연결합니다 |
| 저장된 ID 로 `PERIPHERAL_NOT_FOUND` | 기기가 꺼져 있거나 멀거나, 앱 재설치 · 페어링 삭제로 ID 가 바뀌었습니다 | 다시 스캔해 새 ID 를 저장합니다 |

## FAQ

**Q. `NOT_READY` 와 `ADAPTER_UNAVAILABLE` 은 어떻게 다른가요?**
명령은 `CLIENT_CLOSED` → 어댑터 → 세션 → characteristic 순서로 검사합니다. 블루투스가 꺼져 있으면 세션 상태와 상관없이 `ADAPTER_UNAVAILABLE`,
블루투스는 켜져 있는데 세션이 `ready` 가 아니면 `NOT_READY` 입니다. 앞은 환경 문제(사용자에게 블루투스를 켜 달라고), 뒤는 연결 문제(기다리거나 다시 연결)입니다.
(0.2.1 까지는 두 경우 모두 `NOT_CONNECTED` 였습니다. [CHANGELOG](../CHANGELOG.md) 참고)

**Q. MTU 를 정할 수 있나요?**
없습니다. iOS 가 연결마다 협상합니다. 긴 값은 `write` 가 알아서 나눕니다.

**Q. 본딩(페어링)은 어떻게 하나요?**
iOS 에는 앱이 페어링을 요청하는 API 가 없습니다. 암호화가 필요한 characteristic 에 처음 접근할 때 시스템이 팝업을 띄웁니다.
페어링을 먼저 끝내고 싶으면 연결 직후 그런 characteristic 을 한 번 read 하세요.

**Q. 연결된 기기의 RSSI 를 읽을 수 있나요?**
공개 API 에 없습니다. 스캔 결과의 `rssi` 만 있습니다.

**Q. 여러 Task 에서 같은 세션에 동시에 write 해도 되나요?**
됩니다. 온 순서대로 하나씩 실행되고, 한 write 의 조각 사이에 다른 명령이 끼지 않습니다.

**Q. Task 를 취소하면 기기로 가던 write 도 취소되나요?**
아닙니다. 호출자만 `CancellationError` 로 빠지고, 이미 받아들인 작업은 순서대로 끝까지 갑니다.

**Q. autoReconnect 연결이 영원히 `connecting` 에 있어요.**
autoReconnect 연결에는 기한이 없습니다. 기기가 광고하지 않으면 계속 기다립니다. 앱이 시간을 재서 `disconnect()` 하세요([복구 감시](recipes/connection.md#복구-상태를-보여-주고-너무-오래-걸리면-포기하기)).

**Q. Android 와 코드가 얼마나 같나요?**
실패 코드 문자열, 연결 상태 순서, 명령의 성공 · 실패 조건이 같습니다(두 플랫폼이 같은 계약 시나리오를 통과합니다).
타입 이름 표기(`BLEClient` / `BleClient`), 스트림 타입(`AsyncStream` / `Flow`), 플랫폼에만 있는 기능(Android 본딩 · 진단 로거, iOS 상태 복원)은 다릅니다.

## 한계와 검증 범위

- **검증한 조합:** iPhone XR / iOS 18.7 + nRF52840 시험 펌웨어. 계약 시나리오 39개(가짜 플랫폼), 실기기 23개(Android 와 기록 비교 일치),
  수동 점검 9개(블루투스 끄고 켜기 · 비행기 모드 · 앱 강제 종료(SIGKILL) 뒤 복원 재실행 · 재부팅 뒤 복원 재실행)를 자동으로 돌렸습니다
  (`Samples/ManualTest/auto/run-checklist.sh`).
- **확인하지 않은 것:** 다른 iPhone 모델 · iOS 버전, 여러 기기 동시 연결의 실기기 부하, 페어링이 필요한 기기, 긴 시간(수 시간 이상) 백그라운드 유지.
- **백그라운드에서 처음 보는 기기에 연결하기:** 기기를 찾는 스캔이 서비스 필터 없이 돌아 실패합니다(`PERIPHERAL_NOT_FOUND`). 포그라운드에서 한 번 연결해 두세요.
- **알림 전달 보장:** 핸들러가 값을 받은 직후 저장하기 전에 iOS 가 앱을 죽이면 그 값은 사라집니다. 알림 하나하나가 중요하면 기기와 앱이 확인 응답을 주고받는 프로토콜이 필요합니다(라이브러리 밖).

## 더 읽을거리

- [CHANGELOG](../CHANGELOG.md) — 버전별 변경과 옮기는 법
- [README](../README.md) — 요구 사항 · 설치 · 타깃 구성
- `Samples/ManualTest` — 이 라이브러리를 쓰는 DDD 구조의 시험 앱
