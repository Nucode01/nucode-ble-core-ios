# nucode BLE core — iOS

nucode BLE core 의 iOS 구현 저장소다. 설계 정본과 계약(`contract/`)은 루트 저장소
[pdev-jay/nucode-ble-core](https://github.com/pdev-jay/nucode-ble-core)에 있다.

라이브러리 본체(전달 계획 4단계)는 아직 시작하지 않았다. 지금 있는 것은 시험 지원 target 하나다.

## 지금 있는 것

`BleContract`(Foundation 만 씀, product 로 내보내지 않음)

- 계약 시나리오·peripheral 프로필의 엄격한 로더. 모르는 키·단계·기호는 거부한다
- 기대값 대조기(`ContractMatcher`). `contract/format-tests/match-cases.json`을 통과한다
- 레인 기록(`ContractLog`)과 `CONTRACT|ios|…` 결과 줄
- 단계 순서를 쥔 `ScenarioEngine`과 백엔드 프로토콜 `ScenarioBackend`. 4단계에서 실제 라이브러리로 백엔드를 구현한다

## 시험

루트 저장소 안의 배치(`nucode-ble-core/ios`)라면 `../contract`를 찾는다.

```sh
swift test
```

다른 곳에 받았다면 계약 폴더를 환경 변수로 준다.

```sh
BLE_CONTRACT_DIR=/path/to/nucode-ble-core/contract swift test
```

CI 는 루트 저장소를 읽기 전용 배포 키(`CONTRACT_DEPLOY_KEY`)로 함께 받아 같은 명령을 돌린다.
