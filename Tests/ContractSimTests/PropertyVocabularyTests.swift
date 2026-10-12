@testable import BleContract
import BleContractBackend
import BleCoreFakes
import NucodeBleCore
import Testing

/// 기기 정의 어휘 ↔ 공개 `CharacteristicProperty` (CANDIDATE-30). 러너(API → 계약)와 fake(계약 → API)가
/// 같은 사례 표로 맞는지 본다. Android 러너 자체 시험도 같은 사례를 쓴다
struct PropertyVocabularyTests {
    static let cases: [(contract: String, api: CharacteristicProperty)] = [
        ("read", .read),
        ("write", .writeWithResponse),
        ("writeWithoutResponse", .writeWithoutResponse),
        ("notify", .notify),
        ("indicate", .indicate),
    ]

    @Test(arguments: cases.map { [$0.contract: $0.api] })
    func runnerAndFakeAgree(_ pair: [String: CharacteristicProperty]) {
        let (contract, api) = pair.first!
        #expect(ClientBackend.contractName(api) == contract)
        #expect(FakeCharacteristicSpec.vocabulary[contract] == api)
    }

    @Test func casesCoverBothVocabularies() {
        #expect(Set(Self.cases.map(\.contract)) == PeripheralProfile.knownProperties)
        #expect(Set(Self.cases.map(\.api)) == Set(CharacteristicProperty.allCases))
        #expect(Set(FakeCharacteristicSpec.vocabulary.keys) == PeripheralProfile.knownProperties)
    }
}
