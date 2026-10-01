# nucode BLE core — iOS

nucode BLE core 의 iOS 구현 저장소다. 설계 정본과 계약(`contract/`)은 루트 저장소
[pdev-jay/nucode-ble-core](https://github.com/pdev-jay/nucode-ble-core)에 있다.

> **라이브러리를 쓰려면 [개발자 가이드](guide/README.md)부터 보세요.** 설치 · 스캔 · 연결 · 읽기/쓰기/구독 · 실패 처리 · SwiftUI 연동 · 상태 복원을 예시 코드와 함께 다룹니다.
> 가이드의 예시는 `guide/Snippets` 패키지로 컴파일을 확인하고(`swift build`, 가짜 client 는 `swift test` 로 실행까지) `python3 guide/check_snippets.py` 로 문서와 대조한다.
> 돌아가는 앱으로 보려면 [`Samples/Demo`](Samples/Demo/README.md)(NUS 터미널 데모, SPM 태그로 라이브러리를 받는다)를 본다.

## 구성

`Package.swift` 의 product 는 `NucodeBleCore` 하나다. iOS 17 / macOS 14 이상, Swift 6 언어 모드.

| target | product | 역할 |
|---|---|---|
| `NucodeBleCore` | 예 | 라이브러리 본체. 공개 API 와 CoreBluetooth 위의 구현 |
| `BleContract` | 아니오 | 계약 시나리오·peripheral 프로필 로더, 기대값 대조기, 결과 줄(`CONTRACT|ios|…`), `ScenarioEngine`·`ScenarioBackend` (Foundation 만 씀) |
| `BleContractBackend` | 아니오 | 공개 API 를 `ScenarioBackend` 로 잇는 계약 러너의 공통 부분. sim·device 러너가 같은 소스를 쓴다 |
| `BleCoreFakes` | 아니오 | 가짜 `CentralPort`/`PeripheralPort`(시험 지원) |

## 시험

루트 저장소 안의 배치(`nucode-ble-core/ios`)라면 `../contract`를 찾는다.

```sh
swift test
```

다른 곳에 받았다면 계약 폴더를 환경 변수로 준다.

```sh
BLE_CONTRACT_DIR=/path/to/nucode-ble-core/contract swift test
```

### sim 러너

`ContractSimTests` 가 가짜 포트 위에서 `runsOn: sim` + `platforms: ios` 인 계약 시나리오를 모두 돌려
`CONTRACT|ios|<id>|verdict|PASS` 줄을 출력한다. 쉼표 목록의 `BLE_SIM_ONLY` 를 주면 그 시나리오만 돈다
(sim·ios 대상이 아닌 id 가 있으면 실패한다).

```sh
BLE_SIM_ONLY=<id>,<id> swift test --filter ContractSimTests
```

### device 러너

`DeviceTests/` 는 XCTest 호스트 앱(xcodegen, 서명 팀 `MC4R3V2C33`)이고 `runsOn: device` 시나리오를 실기기(iPhone XR)에서 돈다.
실행은 `lab/run-device.sh <contract 폴더>` 로 한다(종료 코드 0 모두 PASS, 1 FAIL, 2 준비 문제). 기기와 peripheral 이 필요해 `swift test` 에는 들어 있지 않다.

## CI

self-hosted macOS runner 하나에서 돈다. 루트 저장소를 읽기 전용 배포 키(`CONTRACT_DEPLOY_KEY`)로 함께 받아 같은 `swift test` 를 돌린다.
