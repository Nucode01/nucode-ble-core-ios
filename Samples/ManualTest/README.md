# BLE 수동 시험 앱 (ManualTest)

NucodeBleCore 의 릴리스 수동 시험(전달 계획 §6)을 iPhone 에서 돌리는 앱이다. 자동화할 수 없는 항목(블루투스 켜고 끄기,
비행기 모드, 재부팅, 시스템 종료 뒤 복원 재실행)을 사람이 일으키고, 앱은 그동안 일어난 일을 **시간순 기록으로 파일에 남긴다**.
백그라운드 재실행 중에 일어난 일도 나중에 앱을 열어 볼 수 있다. 공개 API 만 쓴다.

- 시험 기기: nRF52840 DK, `contract/peripherals/probe.json` (광고 이름 `Nordic_UART_Service`, NUS 서비스 UUID 광고)
- 번들 ID `kr.co.nucode.ble.ManualTest`, 표시 이름 "BLE 수동 시험", iOS 17+
- 상태 복원: `BLEOptions(restoreIdentifier: "kr.co.nucode.ble.ManualTest.central")`, `UIBackgroundModes: bluetooth-central`

## 계층과 의존 규칙

```
App (SwiftUI, @Observable 모델, 조립 지점)
 │  ├─▶ ManualTestApplication ─▶ ManualTestDomain
 │  └─▶ ManualTestInfrastructure ─▶ ManualTestDomain, NucodeBleCore
 ▼
ManualTestKit (로컬 Swift 패키지)
```

| 계층 | 위치 | 내용 | import |
|---|---|---|---|
| Domain | `ManualTestKit/Sources/ManualTestDomain` | 값 객체(`DeviceId`, `LinkState`, `AdapterStatus`, `ScanStatus`, `ProbeCharacteristic`), 집합체(`TestSession`, `Checklist`), `EventLog`(줄마다 구조화 사실 `LogFact`), `DomainEvent`, 자동 판정(`ChecklistVerdict`, `ChecklistDetectors`), 포트(`BleGateway`, `EventLogStore`, `ChecklistStore`, `RegistrationStore`, `Clock`) | Foundation |
| Application | `ManualTestKit/Sources/ManualTestApplication` | 유스케이스(`StartScan`, `SelectDevice`, `Connect`, `Disconnect`, `Subscribe`, `Unsubscribe`, `ReadValue`, `WriteNus`, `ObserveGateway`, `RecordLaunch`, `MarkChecklistItem`, `ArmChecklistItem`, `EvaluateChecklist`, `ExportReport`, `SaveRegistration`)와 상태 소유자(`ConsoleState`, `ChecklistBoard`) | Foundation, ManualTestDomain |
| Infrastructure | `ManualTestKit/Sources/ManualTestInfrastructure` | `NucodeBleGateway`(라이브러리 어댑터), `Translate`(부패 방지 계층), 파일 저장소, `SystemClock` | + NucodeBleCore |
| Presentation | `App/` | 화면 4개(기기·세션·기록·점검표), `ConsoleModel`·`ChecklistModel`, `AppDelegate` 조립 | SwiftUI, UIKit, 위 셋 |

규칙은 `ArchitectureTests` 가 소스를 읽어 확인한다: Domain 은 Foundation 만, Application 은 Foundation·Domain 만,
`NucodeBleCore` 문자열은 Infrastructure 밖(App 포함)에 나오지 않는다.

도메인은 GATT 명령을 막지 않는다. 판정 대상은 라이브러리이므로 Ready 가 아닐 때의 read·subscribe 도 그대로 넘겨
라이브러리의 거절 코드(`ADAPTER_UNAVAILABLE`, `NOT_READY`)를 기록한다. 도메인이 막는 것은 시험 진행 규칙뿐이다(기기 미선택,
연결 중 기기·autoReconnect 변경).

## 생성·빌드·설치

```sh
cd ios/Samples/ManualTest
(cd ManualTestKit && swift build && swift test)     # 도메인·응용·인프라 단위 시험(macOS)
xcodegen generate                                   # ManualTest.xcodeproj (gitignore)
xcodebuild -project ManualTest.xcodeproj -scheme ManualTest \
  -destination 'generic/platform=iOS' -derivedDataPath build build
xcrun devicectl device install app --device 00008020-0008642C1138003A \
  build/Build/Products/Debug-iphoneos/ManualTest.app
xcrun devicectl device process launch --device 00008020-0008642C1138003A kr.co.nucode.ble.ManualTest
```

첫 실행에서 블루투스 권한 팝업이 뜬다. "허용"을 눌러야 한다(누르기 전까지 어댑터는 `Unknown`).

## 화면

- **기기**: 이름 앞부분(기본 `Nordic_UART_Service`) 또는 NUS 서비스 UUID 로 스캔. 줄을 누르면 시험 대상으로 고른다.
- **세션**: 어댑터·스캔·연결 상태, Ready 횟수(이번 실행), `activeSubscriptions`, 마지막 알림(수·시각·값). autoReconnect,
  연결/해제, probe.value 구독/해제/읽기, NUS rx 쓰기. **앱 시작 등록** 저장/해제.
- **기록**: 모든 사건의 시간순 기록(`L<실행 번호> 시각 [종류] 내용`). 종류로 거른다. 지난 실행의 줄은 주황색 머리글이다.
  실행마다 `실행: 사용자 실행 | 블루투스 복원 재실행(백그라운드)` 줄과 `snapshot(start 직후)`·`snapshot(start+2s)` 줄이 남는다.
- **점검표**: 항목마다 **시작** 버튼, 상태(대기 / 진행 중(남은 시간) / 통과 / 실패 / 사람 확인, 자동·수동 표시), 할 일,
  자동 판정 내용, 펼치는 근거 줄. "수동 판정·메모"로 PASS/FAIL/SKIP/확인을 덮어쓸 수 있다(자동 판정은 멈추고 근거는 남는다).
  복사·공유 버튼은 점검표 결과(자동 판정·근거 포함) + 기록 전체를 텍스트로 낸다.

**자동 판정**: 시작을 누른 순간의 세션 상태(대상, autoReconnect, 연결, 어댑터, 스캔)를 문맥으로 잡고, 그 뒤 기록 줄의 구조화 사실
(어댑터·연결의 직전 상태, 명령을 부른 순간의 어댑터·연결 상태와 실패 코드, 실행의 uptime)만 본다. 새 기록 줄마다, 1초마다(기한),
앱 실행 때 다시 판정한다(8·9 는 재실행 기록으로 판정된다). 규칙과 기한은 `ChecklistDetectors.swift`, 기대는 `contract/states.md`.
기한 안에 기대한 사건이 없으면 실패다. 이전 형식 기록 줄(사실 없음)은 읽지만 판정에 쓰지 않는다.

기록은 `Application Support/ManualTest/events.jsonl`, 점검표는 `checklist.json`, 등록은 `registration.json` 에 쓴다.
세 파일 모두 파일 보호를 끈다(재부팅 뒤 첫 잠금 해제 전 재실행에서도 읽고 쓰게). 그래도 쓰기에 실패하면 세션 화면 "저장 오류"에 나온다.

**실행 판정**: `didFinishLaunching` 때 `applicationState == .background` 면 복원 재실행으로 적는다(이 앱의 백그라운드 모드는
bluetooth-central 뿐이다). `launchOptions` 의 `bluetoothCentrals` 키는 재실행에도 없었으므로(ios-design §13) 참고로만 적는다.

**앱 시작 등록**: `register` 는 `start()` 전에만 되므로 "현재 대상으로 저장"은 **다음 실행부터** 적용된다. 등록이 있으면
실행 때 `register(id, autoReconnect, subscribe: [probe.value])` → `onNotification` → `start()` 순으로 부르고, 복원 재실행이
그 세션을 이어받는다. 등록이 없으면 복원된 연결은 라이브러리가 끊는다.

## 점검 항목별 절차

공통: 기기 탭에서 스캔 → 대상 선택 → 세션 탭에서 연결 → Ready 확인 → probe.value 구독 → 펌웨어에서 알림을 보내
"마지막 알림"이 오르는지 본다. 판정은 기록 탭을 보고 점검표에 적는다.

1. Ready + 구독 상태에서 (스캔도 켜 둔 채) **설정 앱**에서 블루투스를 끈다. 제어 센터 토글은 어댑터를 끄지 않고 연결만 끊을 수
   있어 쓰지 않는다(확인 필요: 제어 센터 토글 때 기록의 adapter 줄).
   기록: `adapter PoweredOff`, 대상의 `Disconnected(Failed:ADAPTER_UNAVAILABLE)`(그 앞 `Recovering(LINK_FAILED)` 는 있어도 됨),
   `scan Idle(Failed:SCAN_STOPPED_BY_ADAPTER)`.
2. 꺼진 채로 "probe.value 읽기", "연결". 기록: connect 와 read 모두 `실패 ADAPTER_UNAVAILABLE`(read 는 GATT 진입 검사가
   어댑터를 세션보다 먼저 본다, contract/states.md §5 명령 진입 검사 순서. 0.2.1 까지는 `NOT_CONNECTED`), 그 뒤 연결 상태 줄이 새로 생기지 않는다.
3. 블루투스를 켠다. 기록: `Connecting → DiscoveringServices → Configuring → Ready` 가 **한 번**, `activeSubscriptions {probe.value}`,
   알림 재개. 세션 탭 Ready 횟수가 1 늘었는지 본다.
4. 해제 → autoReconnect 끔 → 연결 → 1–3 반복. 켠 뒤 연결 상태 줄이 생기지 않아야 한다.
5. 세션 탭에서 **등록 해제**(등록 기기는 어댑터가 켜지면 스스로 연결해 판정을 가린다). 블루투스를 끄고 앱을 종료했다가 실행 →
   연결: `실패 ADAPTER_UNAVAILABLE`. 블루투스를 켜고 곧바로 연결: 즉시 실패하지 않고 진행한다(Unknown 대기 최대 2000ms).
6. 비행기 모드로 1–3 을 반복한다(비행기 모드가 블루투스를 끄는지는 기기 설정에 따른다. 기록의 adapter 줄로 확인).
7. 폰을 재부팅하고 잠금 해제 뒤 앱 실행 → 스캔·연결. 첫 연결이 Ready 에 닿는지 본다.
8. 대상 선택 + autoReconnect 켬 → **현재 대상으로 저장** → 앱 종료(SIGKILL 버튼) 뒤 아이콘으로 다시 실행. 등록 기기는 어댑터가
   켜지면 스스로 연결하고 probe.value 를 구독한다(연결 버튼 불필요). 세션 탭에서 "이번 실행" 등록, Ready, `activeSubscriptions {probe.value}` 확인.
   세션 탭의 **앱 종료(SIGKILL)** 로 프로세스를 죽인다(시스템 종료 흉내, `kill(getpid(), SIGKILL)`). Mac 에서 하려면:
   ```sh
   xcrun devicectl device info processes --device 00008020-0008642C1138003A | grep ManualTest   # PID 확인
   xcrun devicectl device process signal --device 00008020-0008642C1138003A --signal SIGKILL --pid <PID>
   ```
   앱 전환기에서 쓸어 올려 닫으면 사용자 강제 종료라 iOS 가 다시 실행하지 않는다.
   펌웨어에서 probe.value 알림을 보낸다(펌웨어 저장소의 `.venv/bin/python tools/rtt_ctl.py 'NOTIFY 1'`). 몇 초 뒤 앱을 열어 기록을 본다: 새 실행 번호의 `실행: 블루투스 복원 재실행(백그라운드)`,
   snapshot 의 대상 세션 상태, 이후 알림 줄(`probe.value #n`)이 앱을 열기 **전** 시각에 찍혔는지 본다. `앱 active` 줄이 사용자가 연 시점이다.
9. 8 의 준비(등록·연결·구독)까지 한 뒤 폰을 재부팅한다(재부팅 전 앱을 죽일 필요는 없다). 앱을 실행하지 않고 잠금 해제한 뒤 펌웨어 알림을 보낸다.
   나중에 앱을 열어 재실행 줄·알림 줄이 있는지로 판정한다. 없으면 FAIL 이 아니라 관찰 결과로 메모한다(동작 여부 모름 항목).
   `protectedData=false` 인 재실행 줄이 있으면 잠금 해제 전에 깨어난 것이다.

끝나면 점검표 탭의 복사 또는 공유로 보고서를 낸다.

## 자동 실행 (auto/run-checklist.sh)

사람 없이 1–9 를 돌린다. UI 시험 `ManualTestUITests`(설치된 앱에 번들 ID 로 붙고, 블루투스·비행기 모드는 설정 앱으로 바꾼다)와
Mac 쪽 동작(DK RTT 알림, 8 의 SIGKILL, 9·7 의 재부팅)을 순서대로 엮는다. 판정은 앱의 자동 판정이고 끝에 `checklist.json`·`events.jsonl` 을
`build/auto/<시각>/data` 로 복사해 표로 보인다.

```sh
auto/run-checklist.sh                     # 빌드·설치 → prep 1 2 3 6 4 5 8 9(+7) → 보고
auto/run-checklist.sh --from 7            # 재부팅 뒤 이어서(잠금 해제 필요로 멈췄을 때)
auto/run-checklist.sh --only "5 6"        # 그 항목만 다시
PRIME_AIRPLANE=1 auto/run-checklist.sh --only 6   # 비행기 모드가 블루투스를 끄도록 기기 설정을 맞추고 6
```

- 순서: 3 이 Ready·구독을 남기면 곧바로 6, 해제가 필요한 4 는 그 뒤, 앱을 새로 실행하는 5, 등록이 필요한 8, 8 이 남긴 복원 세션으로 9 와 7 을
  재부팅 한 번에(재부팅 전 둘 다 시작) 본다. 자세한 이유는 스크립트 머리말.
- 5 는 등록 없이 새로 실행하면 대상이 없어(꺼진 채 스캔 불가) 같은 실행 안에서 끈 채 실행 → 켜고 스캔·선택 → 끄고 connect → 켜고 곧바로 connect 로 한다.
- 대상 앱을 다시 설치하지 않도록 xctestrun 의 DependentProductPaths 에서 앱을 뺀다(설치는 앱 프로세스·연결을 끊는다).
- 끝(report 뒤)에 `testReleaseDevice` 로 연결·복원 등록을 해제하고 앱을 종료한 뒤, RTT `STATUS` 로 시험 기기가 풀렸는지(conn=0) 본다.
  등록이 남으면 앱을 종료해도 OS 가 연결을 붙들어 다른 폰이 기기를 찾지 못한다. 풀리지 않으면 `LINK_DROP` 으로 끊는다.
  중간에 멈췄고 이어서 돌리지 않을 거면 `auto/run-checklist.sh --only report` 로 정리한다.
