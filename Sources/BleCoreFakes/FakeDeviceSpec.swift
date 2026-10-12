import BleContract
import Foundation
import NucodeBleCore

// MARK: 가짜 기기 정의

package struct FakeServiceSpec: Sendable {
    package let symbol: String
    package let uuid: BLEUUID
    package let advertised: Bool
}

package struct FakeCharacteristicSpec: Sendable {
    package let symbol: String
    package let service: BLEUUID
    package let uuid: BLEUUID
    /// 기기 정의 어휘(`read`·`write`·`writeWithoutResponse`·`notify`·`indicate`)
    package let properties: Set<String>

    /// 기기 정의 어휘 → 공개 타입. 계약의 `write` 는 API 의 `writeWithResponse` 다. 러너의 반대 방향 변환과 같은 사례로 시험한다
    package static let vocabulary: [String: CharacteristicProperty] = [
        "read": .read,
        "write": .writeWithResponse,
        "writeWithoutResponse": .writeWithoutResponse,
        "notify": .notify,
        "indicate": .indicate,
    ]

    /// 탐색 콜백이 넘기는 공개 properties
    package var characteristicProperties: Set<CharacteristicProperty> {
        Set(properties.compactMap { Self.vocabulary[$0] })
    }
}

/// 가짜 기기가 흉내 낼 기기. 기기 정의 파일(`contract/peripherals/<이름>.json`)에서 만든다.
package struct FakeDeviceSpec: Sendable {
    package static let defaultID = PeripheralID(rawValue: "00000000-0000-4000-8000-0000000000a1")

    package let id: PeripheralID
    package let advertisedName: String
    package let services: [FakeServiceSpec]
    package let characteristics: [FakeCharacteristicSpec]

    package init(
        id: PeripheralID = FakeDeviceSpec.defaultID,
        advertisedName: String,
        services: [FakeServiceSpec],
        characteristics: [FakeCharacteristicSpec]
    ) {
        self.id = id
        self.advertisedName = advertisedName
        self.services = services
        self.characteristics = characteristics
    }

    /// 기호 이름 순으로 정렬해 순서를 정한다(정의 파일의 객체는 순서가 없다)
    package init(profile: PeripheralProfile, id: PeripheralID = FakeDeviceSpec.defaultID) throws {
        func uuid(_ text: String) throws -> BLEUUID {
            guard let value = BLEUUID(string: text) else { throw ContractError("not a UUID: \(text)") }
            return value
        }
        self.init(
            id: id,
            advertisedName: profile.advertisedName,
            services: try profile.services.keys.sorted().map { symbol in
                let service = profile.services[symbol]!
                return FakeServiceSpec(symbol: symbol, uuid: try uuid(service.uuid), advertised: service.advertised)
            },
            characteristics: try profile.characteristics.keys.sorted().map { symbol in
                let characteristic = profile.characteristics[symbol]!
                return FakeCharacteristicSpec(
                    symbol: symbol,
                    service: try uuid(characteristic.service),
                    uuid: try uuid(characteristic.uuid),
                    properties: Set(characteristic.properties)
                )
            }
        )
    }
}

/// 가짜 기기의 지연(밀리초, 시계 배율 이전의 계약 시간). contract/README §sim 가짜 기기.
package struct FakeTiming: Sendable {
    /// 스캔 중 결과 하나가 나오는 간격
    package var scanInterval = 100
    /// 연결 간격 하나. 요청 하나의 응답이 오는 데 드는 시간
    package var connectionInterval = 15
    /// 광고 중인 기기에 대기 connect 가 붙기까지
    package var attachDelay = 50
    /// 링크를 건드리는 기기 사건이 쓰기 응답 뒤 실행되기까지(펌웨어 동작)
    package var deviceEventDelay = 300
    /// 쓰기 응답이 필요한 값을 나눠 받는 ATT PDU 크기. 조각이 `singlePDULimit` 이하면 PDU 하나다.
    package var pduBytes = 60
    package var singlePDULimit = 62
    /// 응답 없는 쓰기 버퍼: 패킷 하나가 나가는 간격과 용량
    package var transmitInterval = 5
    package var transmitCapacity = 12

    package init() {}
}
