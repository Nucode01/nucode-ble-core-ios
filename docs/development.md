# 개발 안내

이 저장소에서 라이브러리를 빌드하고 시험하는 법을 적습니다.

## 저장소

| 저장소 | 주소 | 쓰임 |
|---|---|---|
| 메인 | 사내 Azure DevOps(주소는 사내 문서) | 개발 · push |
| 미러 (GitHub) | `https://github.com/Nucode01/nucode-ble-core-ios.git` | SwiftPM 설치 · CI |

GitHub 저장소는 Azure 저장소의 미러입니다. 사람은 Azure 에만 push 합니다.
Azure Pipelines(`azure-pipelines.yml`)가 Azure 의 main 과 태그를 GitHub 미러로 옮깁니다. 그래서 커밋과 태그는 Azure 에 먼저 올라가고 GitHub 에는 파이프라인이 태그까지 옮깁니다.
파이프라인은 `--mirror` · `--force` 를 쓰지 않습니다. 미러의 이력이 갈라지면 push 가 실패합니다.
SwiftPM 소비자는 미러의 태그를 받습니다. 미러의 태그 push 가 GitHub Actions CI 를 돌립니다.

파이프라인을 쓰려면 사용자가 아래를 한 번 설정합니다.

1. Azure DevOps 에서 이 저장소의 `azure-pipelines.yml` 로 파이프라인을 만듭니다.
2. 파이프라인에 비밀 변수 `GITHUB_MIRROR_TOKEN` 을 둡니다. 값은 미러 저장소의 Contents 쓰기와 Workflows 쓰기 권한이 있는 GitHub 토큰입니다. Workflows 권한이 없으면 `.github/workflows/` 를 바꾼 커밋의 push 가 실패합니다.
3. 조직에서 Microsoft-hosted 병렬 작업을 쓸 수 있는지 확인합니다.

## 계약 폴더

`swift test` 의 계약 시나리오 시험은 계약 폴더(`scenarios/`, `peripherals/`, 실패 코드 표가 든 `contract` 폴더)가 필요합니다.
시험은 환경 변수 `BLE_CONTRACT_DIR` 를 먼저 봅니다. 값이 없으면 이 패키지 폴더 옆의 `../contract` 를 씁니다.
`BLE_CONTRACT_DIR` 가 없고 `../contract` 도 없으면, 계약 폴더를 읽는 시험은 "계약 폴더 없음" 이유로 건너뜁니다. 나머지 시험은 그대로 돕니다.
`BLE_CONTRACT_DIR` 를 줬는데 그 폴더가 없으면 시험이 실패합니다.

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

CI 는 GitHub 미러에서 GitHub-hosted macOS runner(`macos-15`) 하나로 `swift test` 를 돌립니다.
CI 는 태그 push 와 수동 실행(`workflow_dispatch`) 때만 돕니다. main push 와 PR 에서는 돌지 않습니다.
미러에는 계약 폴더가 없어 CI 는 계약 폴더를 읽는 시험을 건너뜁니다.
계약 시험은 계약 폴더가 있는 로컬에서 돌립니다.
