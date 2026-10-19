# 개발 안내

이 저장소에서 라이브러리를 빌드하고 시험하는 법을 적습니다.

## 계약 폴더

`swift test` 의 계약 시나리오 시험은 계약 폴더(`scenarios/`, `peripherals/`, 실패 코드 표가 든 `contract` 폴더)가 필요합니다.
시험은 환경 변수 `BLE_CONTRACT_DIR` 를 먼저 봅니다. 값이 없으면 이 패키지 폴더 옆의 `../contract` 를 씁니다.

```sh
BLE_CONTRACT_DIR=/path/to/contract swift test
```

## sim 러너

`ContractSimTests` 가 가짜 포트 위에서 `runsOn: sim` + `platforms: ios` 인 계약 시나리오를 모두 돌립니다.
시나리오마다 `CONTRACT|ios|<id>|verdict|PASS` 줄을 출력합니다.
쉼표 목록의 `BLE_SIM_ONLY` 를 주면 그 시나리오만 돕니다. sim · ios 대상이 아닌 id 가 있으면 실패합니다.

```sh
BLE_SIM_ONLY=<id>,<id> swift test --filter ContractSimTests
```

## device 러너

`DeviceTests/` 는 XCTest 호스트 앱(xcodegen, 서명 팀 `MC4R3V2C33`)입니다. `runsOn: device` 시나리오를 실기기(iPhone XR)에서 돌립니다.
실행 명령은 `lab/run-device.sh <contract 폴더>` 입니다.
종료 코드는 0 이 모두 PASS, 1 이 FAIL 있음, 2 가 준비 문제입니다.
기기와 peripheral 이 필요해 `swift test` 에는 들어 있지 않습니다.

## CI

CI 는 self-hosted macOS runner 하나에서 `swift test` 를 돌립니다.
CI 는 태그 push 와 수동 실행(`workflow_dispatch`) 때만 돕니다. main push 와 PR 에서는 돌지 않습니다.
CI 는 계약 폴더를 계약 저장소(`pdev-jay/nucode-ble-core`)에서 읽기 전용 배포 키(`CONTRACT_DEPLOY_KEY`)로 받습니다.
태그 실행은 계약 저장소의 같은 이름 태그에서 계약을 받습니다. 브랜치에서 수동으로 돌리면 계약 저장소의 main 에서 받습니다.
계약 저장소에 같은 이름의 태그가 없으면 checkout 이 실패합니다. 그래서 계약 저장소에 태그를 먼저 push 하고 이 저장소에 태그를 push 합니다.
