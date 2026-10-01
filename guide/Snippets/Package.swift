// swift-tools-version: 6.0
import PackageDescription

// 가이드 예시 코드의 컴파일 확인용 패키지. 라이브러리 밖의 소비자 자리라 공개 API 만 보인다.
// 문서의 코드 블록은 이 소스의 `// region guide:<이름>` 블록과 글자 그대로 같다(../check_snippets.py 가 대조한다)
let package = Package(
    name: "GuideSnippets",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        // Snippets → guide → ios
        .package(path: "../.."),
    ],
    targets: [
        .target(name: "GuideSnippets", dependencies: [.product(name: "NucodeBleCore", package: "ios")]),
        // 컴파일만으로는 못 잡는 예시(가짜 client 의 교착·replay 등)를 실제로 돌려 본다
        .testTarget(name: "GuideSnippetsTests", dependencies: ["GuideSnippets", .product(name: "NucodeBleCore", package: "ios")]),
    ],
    swiftLanguageModes: [.v6]
)
