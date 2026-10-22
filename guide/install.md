# 2. 설치

## 2.1 Swift Package 추가

**Xcode 앱 프로젝트:** File › Add Package Dependencies… 에서 아래 URL 을 넣고, Dependency Rule 은 `Up to Next Minor Version` 에 `0.4.0` 을 줍니다.
product `NucodeBleCore` 를 앱 target 에 추가합니다.

```text
https://github.com/Nucode01/nucode-ble-core-ios.git
```

**Swift Package:**

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Nucode01/nucode-ble-core-ios.git", .upToNextMinor(from: "0.4.0")),
],
targets: [
    .target(name: "MyFeature", dependencies: [.product(name: "NucodeBleCore", package: "nucode-ble-core-ios")]),
]
```

**같은 머신의 소스를 바로 쓸 때**(라이브러리를 같이 고치는 중): Xcode 에서 Add Local… 로 이 저장소를 받은 폴더를 고르거나
`.package(path: "../nucode-ble-core-ios")`(받은 폴더 경로)를 씁니다.

> 0.x 동안에는 minor 가 바뀔 때 호환이 깨질 수 있어 `upToNextMinor` 를 권합니다. 바뀌는 내용은 [CHANGELOG](../CHANGELOG.md)에 있습니다.

## 2.2 Info.plist

| 키 | 필요할 때 | 값 |
|---|---|---|
| `NSBluetoothAlwaysUsageDescription` | **항상** | 권한 팝업에 보일 문구. 예: "주변 기기와 연결하려고 블루투스를 사용합니다" |
| `UIBackgroundModes` 에 `bluetooth-central` | 백그라운드에서 연결 유지 · 알림 수신, 상태 복원 | 배열 항목 `bluetooth-central` |

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>주변 기기와 연결하려고 블루투스를 사용합니다</string>
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
</array>
```

빠뜨렸을 때 라이브러리가 하는 일:

- **`NSBluetoothAlwaysUsageDescription` 이 없음** → `start()` 가 CoreBluetooth 를 만들지 않고(만들면 iOS 가 앱을 죽입니다)
  `adapterStates` 를 `.unauthorized(canRequest: false)` 로 알립니다. 명령은 `PERMISSION_DENIED` 로 실패합니다. 크래시하지 않습니다.
- **`BLEOptions(restoreIdentifier:)` 를 줬는데 `bluetooth-central` 이 없음** → `start()` 에서 trap 합니다(설정 실수를 개발 중에 바로 알리려는 것입니다).
- **`bluetooth-central` 없이 백그라운드로 감** → 앱이 일시정지되면 연결 이벤트와 알림을 받지 못합니다. 라이브러리가 따로 알리지 않습니다.

Xcode 에서는 target › Signing & Capabilities › + Capability › Background Modes › "Uses Bluetooth LE accessories" 를 켜면 두 번째 키가 들어갑니다.

## 2.3 권한 팝업 시점

권한 팝업은 `client.start()` 에서 뜹니다(그때 `CBCentralManager` 를 만들기 때문입니다).
앱 첫 화면에서 바로 팝업을 띄우고 싶지 않으면, 설명 화면을 보여 준 뒤 `start()` 를 부르세요.
아직 물어본 적이 있는지는 `CoreBluetooth` 의 `CBManager.authorization` 으로 manager 없이 알 수 있습니다.

```swift
import CoreBluetooth

if CBManager.authorization == .notDetermined {
    // 설명 화면 → 사용자가 "계속"을 누르면 client.start()
} else {
    client.start()
}
```

`start()` 를 부르기 전의 `connect()` · `startScan()` 은 어댑터 판정을 최대 2초 기다린 뒤 `ADAPTER_UNAVAILABLE` 로 실패합니다.
`start()` 뒤 팝업이 떠 있는 동안에는 사용자가 답할 때까지 기다립니다.

**상태 복원을 쓰는 앱은 예외입니다.** 시스템이 앱을 백그라운드에서 다시 실행할 때 `start()` 가 불려야 복원을 받으므로,
`application(_:didFinishLaunchingWithOptions:)` 에서 바로 부릅니다. 자세한 것은 [앱 구조에 넣기](recipes/app-integration.md#상태-복원)를 보세요.

## 2.4 확인

아래가 되면 설치가 끝난 것입니다.

```swift
import NucodeBleCore

let client = BLEClientFactory.make()
client.start()
for await state in client.adapterStates {
    print(state) // unknown → (팝업 허용 뒤) ready
    if case .ready = state { break }
}
```

시뮬레이터에는 블루투스가 없습니다. `ready` 를 보려면 실기기에서 실행하세요.
