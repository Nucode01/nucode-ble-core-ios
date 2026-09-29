// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NucodeBleCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    // 라이브러리 product 는 4단계에서 추가한다. BleContract 는 시험 지원이라 product 로 내보내지 않는다
    products: [],
    targets: [
        .target(name: "BleContract"),
        .testTarget(name: "BleContractTests", dependencies: ["BleContract"]),
    ],
    swiftLanguageModes: [.v6]
)
