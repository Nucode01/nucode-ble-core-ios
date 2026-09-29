// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NucodeBleCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    // BleContract·BleCoreFakes 는 시험 지원이라 product 로 내보내지 않는다
    products: [
        .library(name: "NucodeBleCore", targets: ["NucodeBleCore"]),
    ],
    targets: [
        .target(name: "BleContract"),
        .target(name: "NucodeBleCore"),
        // 가짜 플랫폼(시험 지원). product 로 내보내지 않는다
        .target(name: "BleCoreFakes", dependencies: ["NucodeBleCore", "BleContract"]),
        // 계약 러너의 공통 부분: 공개 API 를 ScenarioBackend 로 잇는다. sim·device 러너가 같은 소스를 쓴다(product 아님)
        .target(name: "BleContractBackend", dependencies: ["BleContract", "NucodeBleCore"]),
        .testTarget(name: "BleContractTests", dependencies: ["BleContract"]),
        .testTarget(name: "NucodeBleCoreTests", dependencies: ["NucodeBleCore", "BleCoreFakes", "BleContract"]),
        .testTarget(name: "ContractSimTests", dependencies: ["BleContractBackend", "BleCoreFakes", "BleContract", "NucodeBleCore"]),
    ],
    swiftLanguageModes: [.v6]
)
