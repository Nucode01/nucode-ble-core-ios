# BLE 데모 (NUS 터미널)

NucodeBleCore 를 일반 앱처럼 쓰는 SwiftUI 데모입니다. 주변 기기를 스캔해 고르고, Nordic UART Service(NUS)로 텍스트를 주고받습니다.
연결 상태 · 자동 재연결 · 블루투스 끄고 켜기 · 실패 문구 · 라이브러리 이벤트 로그를 한 화면에서 볼 수 있습니다.

라이브러리는 **실제 소비자처럼 SPM URL 의 태그**(`https://github.com/pdev-jay/nucode-ble-core-ios.git`, `exactVersion: 0.2.2`)로 받습니다. 검증할 태그 하나로만 빌드하려고 고정합니다(앱에는 [설치 안내](../../guide/install.md)의 `upToNextMinor` 를 권합니다).
이 저장소의 소스를 고쳐도 데모에는 새 태그를 받기 전까지 반영되지 않습니다.

## 구조

| 파일 | 역할 |
|---|---|
| `App/DemoApp.swift` | 앱 진입점. `BLEController` 하나를 만들어 화면에 내려 줌 |
| `App/BLEController.swift` | `BLEClient` 의 유일한 소유자(앱 수명). 어댑터 · 스캔 · 이벤트 · 최근 기기 · 기기별 터미널 캐시 |
| `App/TerminalController.swift` | 기기 하나의 연결 · 송수신 · 대화 줄. `any BLESession` 을 받아 단위 시험에서 가짜 세션으로 바꿔 끼운다 |
| `App/ScanScreen.swift` · `TerminalScreen.swift` · `EventLogScreen.swift` | 화면 |
| `App/Support.swift` | 가이드 예시와 같은 도우미(`NUS`, `waitUntilReady`, `userMessage`, `adapterMessage`)와 경계 로그 `boundaryLog` |
| `Tests/` | `TerminalController` 단위 시험, 구조 규칙 시험(`BLEClient(` 는 `BLEController.swift` 에만, `import CoreBluetooth` 없음) |

라이브러리 사용 방법의 설명은 [개발자 가이드](../../guide/README.md)에 있습니다. 이 앱의 코드는 가이드의 패턴을 그대로 씁니다.

## 빌드 · 시험 · 설치

필요: Xcode 26, [xcodegen](https://github.com/yonaskolb/XcodeGen), `pdev-jay/nucode-ble-core-ios` 읽기 권한(비공개 저장소), 서명 팀 `MC4R3V2C33`.

```sh
cd ios/Samples/Demo
xcodegen generate

# 실기기용 빌드
xcodebuild -project BLEDemo.xcodeproj -scheme BLEDemo -destination 'generic/platform=iOS' -derivedDataPath .build/dd build

# 단위 시험(시뮬레이터)
xcodebuild test -project BLEDemo.xcodeproj -scheme BLEDemo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .build/dd

# 연결된 iPhone 에 설치 · 실행
xcrun devicectl device install app --device <UDID> .build/dd/Build/Products/Debug-iphoneos/BLEDemo.app
xcrun devicectl device process launch --device <UDID> kr.co.nucode.ble.Demo
```

Xcode 에서 열어도 됩니다: `open BLEDemo.xcodeproj` 후 실기기를 골라 Run. 시뮬레이터에는 블루투스가 없어 화면만 확인할 수 있습니다.

## 시연 절차 (nRF52840 DK + 시험 펌웨어)

시험 펌웨어(`peripheral_uart`)는 `Nordic_UART_Service` 라는 이름으로 광고하고 **연결을 하나만** 받습니다.

0. **준비.** 다른 앱(예: `Samples/ManualTest` 의 등록)이 DK 를 붙잡고 있으면 스캔에 보이지 않습니다. RTT `STATUS` 로 `conn=0` 을 확인하거나 그 앱의 연결을 끊습니다.
1. **스캔.** "스캔" → 목록에 `Nordic_UART_Service` 와 RSSI · `NUS` 표시가 보입니다. "NUS 서비스만" 을 끄면 주변의 모든 광고가 보입니다.
2. **연결.** 기기를 눌러 터미널로 가서 "연결" → 상태가 `연결 중 → 서비스 찾는 중 → 설정 중 → 준비됨` 으로 바뀝니다.
3. **송수신.** 빠른 명령 `IT:STATUS` → 보낸 줄 하나와 `IT|STATUS|part=LINK…` · `part=SUB…` · `part=RX…` 받은 줄 세 개.
   빠른 명령은 이 시험 펌웨어 전용입니다. 다른 기기에서는 입력창으로 그 기기의 명령을 보냅니다.
4. **자동 재연결.** (메뉴의 "자동 재연결" 이 켜진 채 연결했을 때) `IT:DISCONNECT` → 기기가 100ms 뒤 연결을 끊고,
   상태가 `다시 연결하는 중 (LINK_FAILED)` → … → `준비됨` 으로 돌아옵니다. 다시 `IT:STATUS` 를 보내면 응답이 옵니다(구독은 라이브러리가 복원).
5. **블루투스 끄고 켜기.** 제어 센터가 아니라 **설정 › Bluetooth** 에서 끕니다(제어 센터는 연결만 끊고 어댑터를 끄지 않습니다).
   상단에 안내가 뜨고 상태가 `블루투스 꺼짐 — 켜지면 자동 재연결` 이 됩니다. 꺼진 채 빠른 명령을 누르면 "블루투스를 켜 주세요" 오류 줄. 다시 켜면 자동으로 `준비됨`.
6. **이벤트 로그.** 스캔 화면 위 "이벤트" 에서 라이브러리 `client.events` 의 연결 전이가 시간순으로 보입니다.
7. **최근 기기.** 앱을 완전히 종료했다 다시 열면 "최근 기기" 에 마지막으로 연결한 기기가 있고, 스캔 없이 연결할 수 있습니다.

## 하지 않는 것

- 상태 복원(시스템이 앱을 종료한 뒤 재실행). `Samples/ManualTest` 와 가이드의 [상태 복원](../../guide/recipes/app-integration.md#상태-복원)을 보세요.
- 여러 기기 동시 연결 화면. 목록에서 기기를 오가며 각각 연결해 둘 수는 있습니다(기기별 터미널이 유지됩니다).
