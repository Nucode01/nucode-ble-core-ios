// swift-tools-version: 6.0
import PackageDescription

// 수동 시험 앱의 도메인·응용·인프라 계층. 의존은 Infrastructure → Application → Domain 한 방향이다(README 참고)
let package = Package(
    name: "ManualTestKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ManualTestDomain", targets: ["ManualTestDomain"]),
        .library(name: "ManualTestApplication", targets: ["ManualTestApplication"]),
        .library(name: "ManualTestInfrastructure", targets: ["ManualTestInfrastructure"]),
    ],
    dependencies: [
        // ManualTestKit → ManualTest → Samples → ios
        .package(path: "../../.."),
    ],
    targets: [
        .target(name: "ManualTestDomain"),
        .target(name: "ManualTestApplication", dependencies: ["ManualTestDomain"]),
        .target(
            name: "ManualTestInfrastructure",
            dependencies: ["ManualTestDomain", .product(name: "NucodeBleCore", package: "ios")]
        ),
        .testTarget(
            name: "ManualTestKitTests",
            dependencies: ["ManualTestDomain", "ManualTestApplication", "ManualTestInfrastructure"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
