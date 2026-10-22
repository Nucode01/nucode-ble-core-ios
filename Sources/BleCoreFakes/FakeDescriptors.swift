import Foundation
import NucodeBleCore

// MARK: 가짜 기기의 descriptor (contract/README §sim 가짜 기기, CANDIDATE-32)
// FakePeripheral.swift 가 400줄을 넘지 않게 따로 둔다
//
// - 탐색: 기기 정의의 `descriptors` 를 정의 순서대로 그 characteristic 아래에 둔다.
// - 값: 연결마다 정의의 `value` 로 돌아간다. `write` 속성이 있으면 쓴 값을 다음 read 가 돌려준다.
//   `read`·`write` 속성이 없으면 ATT Read·Write Not Permitted 로 실패한다.
// - CCCD(0x2902): 값은 그 characteristic 의 구독 상태다(notify `0100`, indicate `0200`, 꺼짐 `0000`).

extension FakePeripheral {
    private static let cccdUUID = BLEUUID(string: "2902")!

    /// 포트 참조: characteristic 의 포트 참조 + 같은 UUID 사이 순서
    private func descriptorEntries(of characteristic: CharacteristicRef) -> [(ref: DescriptorRef, spec: FakeDescriptorSpec)] {
        var seen: [BLEUUID: Int] = [:]
        return (characteristicSpecs[characteristic]?.descriptors ?? []).map { spec in
            let index = seen[spec.uuid, default: 0]
            seen[spec.uuid] = index + 1
            return (DescriptorRef(characteristic: characteristic, uuid: spec.uuid, instanceIndex: index), spec)
        }
    }

    private func descriptorSpec(_ descriptor: DescriptorRef) -> FakeDescriptorSpec? {
        descriptorEntries(of: descriptor.characteristic).first { $0.ref == descriptor }?.spec
    }

    private func descriptorValue(_ descriptor: DescriptorRef, _ spec: FakeDescriptorSpec) -> Data {
        guard spec.uuid == Self.cccdUUID else { return descriptorValues[descriptor] ?? spec.value ?? Data() }
        guard subscribed.contains(descriptor.characteristic) else { return Data([0x00, 0x00]) }
        let notifies = characteristicSpecs[descriptor.characteristic]?.properties.contains("notify") ?? false
        return Data([notifies ? 0x01 : 0x02, 0x00])
    }

    package func discoverDescriptors(for characteristic: CharacteristicRef) {
        respond { device in
            let found = device.descriptorEntries(of: characteristic).map(\.ref)
            device.delegate?.peripheral(device, didDiscoverDescriptors: found, for: characteristic, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didDiscoverDescriptors: [], for: characteristic, error: error)
        }
    }

    package func readValue(for descriptor: DescriptorRef) {
        guard let spec = descriptorSpec(descriptor), spec.properties.contains("read") else {
            reject(PortError(domain: "FakePeripheral", code: 2, message: "reading is not permitted")) { device, error in
                device.delegate?.peripheral(device, didUpdateValue: nil, for: descriptor, error: error)
            }
            return
        }
        respond { device in
            device.delegate?.peripheral(device, didUpdateValue: device.descriptorValue(descriptor, spec), for: descriptor, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didUpdateValue: nil, for: descriptor, error: error)
        }
    }

    package func writeValue(_ data: Data, for descriptor: DescriptorRef) {
        descriptorWriteCalls += 1
        guard let spec = descriptorSpec(descriptor), spec.properties.contains("write") else {
            reject(PortError(domain: "FakePeripheral", code: 3, message: "write is not permitted")) { device, error in
                device.delegate?.peripheral(device, didWriteValueFor: descriptor, error: error)
            }
            return
        }
        respond { device in
            device.descriptorValues[descriptor] = Data(data)
            device.delegate?.peripheral(device, didWriteValueFor: descriptor, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didWriteValueFor: descriptor, error: error)
        }
    }
}
