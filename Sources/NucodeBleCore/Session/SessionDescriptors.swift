import Foundation

// MARK: GATT 명령: descriptor (CANDIDATE-32, api-contract §descriptor 계약)
// Session.swift 는 baseline 400줄 초과라 descriptor 명령과 그 콜백을 따로 둔다

extension Session {
    /// CCCD(0x2902). iOS 는 이 descriptor 를 `setNotifyValue` 로만 바꾼다
    private static let cccdUUID = BLEUUID(string: "2902")!
    /// 속성 값 최대 길이(ATT). 넘으면 보내지 않는다
    private static let maximumAttributeLength = 512

    /// 진입 검사 1~4(states.md §5 명령 진입 검사 순서). characteristic 까지는 `admitGatt` 와 같고, 4 는 descriptor 까지 본다.
    /// 통과하면 포트 참조. 확인과 큐 접수 사이에는 `await` 가 없다
    private func admitDescriptor(_ descriptor: DescriptorRef) async throws -> DescriptorRef {
        _ = try await admitGatt(descriptor.characteristic)
        guard let portRef = portDescriptorRefs[descriptor] else {
            throw BLEError(failure: BLEFailure(code: .characteristicNotFound, message: "이 기기에 없는 descriptor 다"))
        }
        return portRef
    }

    /// read 와 같은 큐 · 기한 · 끊김 규칙. 작업 대기는 마지막 줄의 한 번뿐이다
    package func readDescriptor(_ descriptor: DescriptorRef) async throws -> Data {
        let portRef = try await admitDescriptor(descriptor)
        let waiter = operations.submit(.readDescriptor, characteristic: portRef.characteristic, descriptor: portRef, start: { [weak self] in
            self?.peripheral?.readValue(for: portRef)
        })
        return try await waiter.value()
    }

    /// 응답 있는 쓰기 한 번, 나누지 않는다. 진입 검사 5: CCCD 는 플랫폼에 닿기 전에 거절하므로 구독 상태가 바뀌지 않는다
    package func writeDescriptor(_ descriptor: DescriptorRef, _ value: Data) async throws {
        let portRef = try await admitDescriptor(descriptor)
        guard descriptor.uuid != Self.cccdUUID else {
            throw BLEError(failure: BLEFailure(
                code: .descriptorWriteNotAllowed,
                message: "iOS 는 CCCD 를 subscribe · unsubscribe 로만 바꾼다"
            ))
        }
        guard value.count <= Self.maximumAttributeLength else {
            throw BLEError(failure: BLEFailure(
                code: .payloadTooLarge,
                message: "descriptor 값 \(value.count) 바이트가 최대 \(Self.maximumAttributeLength) 바이트를 넘는다"
            ))
        }
        let waiter = operations.submit(.writeDescriptor, characteristic: portRef.characteristic, descriptor: portRef, start: { [weak self] in
            self?.peripheral?.writeValue(value, for: portRef)
        })
        _ = try await waiter.value()
    }

    // MARK: 콜백 (`p === peripheral` 과 세대가 맞을 때만)

    package func peripheralDidDiscoverDescriptors(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        descriptors: [DescriptorRef],
        for characteristic: CharacteristicRef,
        error: PortError?
    ) {
        discoveringSetup(candidate, generation: generation)?.didDiscoverDescriptors(descriptors, for: characteristic, error: error)
    }

    package func peripheralDidUpdateDescriptorValue(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        value: Data?,
        for descriptor: DescriptorRef,
        error: PortError?
    ) {
        guard acceptsGattCallback(candidate, generation: generation) else { return }
        if !operations.didUpdateDescriptorValue(for: descriptor, value: value, error: error) {
            context.events.emit(.diagnostic(code: .gattOperationCallbackMismatch, message: "진행 중인 readDescriptor 가 없는데 descriptor 값 콜백이 왔다"))
        }
    }

    package func peripheralDidWriteDescriptorValue(
        _ candidate: any PeripheralPort,
        generation: UInt64,
        for descriptor: DescriptorRef,
        error: PortError?
    ) {
        guard acceptsGattCallback(candidate, generation: generation) else { return }
        if !operations.didWriteDescriptorValue(for: descriptor, error: error) {
            context.events.emit(.diagnostic(code: .gattOperationCallbackMismatch, message: "진행 중인 writeDescriptor 가 없는데 descriptor 쓰기 콜백이 왔다"))
        }
    }
}
