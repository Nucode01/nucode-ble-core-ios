# NucodeBleCore

iOS 앱이 BLE 기기(peripheral)에 **central** 로 붙을 때 쓰는 Swift 라이브러리입니다.
CoreBluetooth 위에서 스캔 · 연결 · 서비스 탐색 · read · write · 구독 · 재연결 · 상태 복원을 `async/await` API 로 제공합니다.
모든 실패는 바뀌지 않는 코드와 재시도 가능성을 가진 `BLEFailure` 로 옵니다.
Android 판(`kr.co.nucode:ble-core`)과 같은 상태 순서 · 실패 코드를 씁니다.

## 요구 사항

| 항목 | 값 |
|---|---|
| 최소 버전 | iOS 17 / macOS 14 |
| 언어 | Swift 6 언어 모드 |
| 의존성 | 없음 (Foundation · CoreBluetooth) |

## 설치

Swift Package Manager 로 추가합니다.

```swift
.package(url: "https://github.com/Nucode01/nucode-ble-core-ios.git", .upToNextMinor(from: "0.4.0")),
```

product 는 `NucodeBleCore` 입니다. Info.plist 항목과 권한 팝업 시점은 [설치 안내](guide/install.md)에 있습니다.

## 가이드

[개발자 가이드](guide/README.md)가 설치 · 스캔 · 연결 · 읽기/쓰기/구독 · 실패 처리 · SwiftUI 연동 · 상태 복원을 예시 코드와 함께 다룹니다.
돌아가는 앱으로 보려면 [`Samples/Demo`](Samples/Demo/README.md)(NUS 터미널 데모)를 봅니다.

## 타깃

공개 product 는 `NucodeBleCore` 하나입니다. 나머지 타깃은 이 저장소의 시험에만 씁니다.

| target | product | 역할 |
|---|---|---|
| `NucodeBleCore` | 예 | 라이브러리 본체. 공개 API 와 CoreBluetooth 위의 구현 |
| `BleContract` | 아니오 | 계약 시나리오 실행기와 기대값 대조기(시험 지원) |
| `BleContractBackend` | 아니오 | 공개 API 를 계약 시나리오 실행기에 잇는 부분(시험 지원) |
| `BleCoreFakes` | 아니오 | 가짜 `CentralPort`/`PeripheralPort`(시험 지원) |

## 개발

```sh
swift build
swift test
```

계약 시나리오 시험을 돌리는 법, 실기기 시험, CI 는 [개발 안내](docs/development.md)에 있습니다.

## 변경 이력

버전별 변경과 옮기는 법은 [CHANGELOG](CHANGELOG.md)에 있습니다.
