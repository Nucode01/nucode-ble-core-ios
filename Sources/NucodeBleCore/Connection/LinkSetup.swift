import Foundation

/// 링크가 붙은 뒤의 서비스 탐색 한 번(docs/v1/ios-design.md §6). 연결 경로는 하나이므로 원인과 무관하게 이 부품을 거친다.
/// `discoverServices(nil)` → 모든 서비스의 characteristic 탐색 → characteristic 마다 descriptor 탐색(CANDIDATE-32) → 서비스 목록.
/// 결과(`onFinish`)는 정확히 한 번 나간다. instanceIndex 는 같은 UUID 인스턴스 사이의 순서로 여기서 정한다(CANDIDATE-29).
/// descriptor 단계는 characteristic 하나당 왕복 하나라 Ready 를 그만큼 늦춘다. 기한(`Deadlines.discovery`)은 이 단계까지 덮는다.
@BLECoreActor
package final class LinkSetup {
    package enum Outcome {
        case success([GATTService])
        case failure(BLEFailure)
    }

    private struct PendingService {
        let portRef: ServiceRef
        let ref: ServiceRef
        var characteristics: [GATTCharacteristic]?
    }

    private let peripheral: any PeripheralPort
    private let clock: any BLEClock
    private let diagnostic: @BLECoreActor (FailureCode, String) -> Void
    private var onFinish: (@BLECoreActor (Outcome) -> Void)?
    private var pending: [PendingService] = []
    private var listed = false
    private var deadline: Task<Void, Never>?
    /// 공개 참조 → 플랫폼(포트)이 준 참조. 성공한 탐색에서만 채워진다. 플랫폼 호출에는 이쪽을 넘긴다
    private(set) package var portRefs: [CharacteristicRef: CharacteristicRef] = [:]
    /// descriptor 의 공개 참조 → 포트 참조. 성공한 탐색에서만 채워진다
    private(set) package var portDescriptorRefs: [DescriptorRef: DescriptorRef] = [:]
    /// 포트 characteristic 참조 → 포트가 준 descriptor(탐색 순서). 탐색을 요청한 것만 키가 있고, 답이 오면 값이 생긴다
    private var descriptorResults: [CharacteristicRef: [DescriptorRef]?] = [:]

    package init(
        peripheral: any PeripheralPort,
        clock: any BLEClock,
        diagnostic: @escaping @BLECoreActor (FailureCode, String) -> Void,
        onFinish: @escaping @BLECoreActor (Outcome) -> Void
    ) {
        self.peripheral = peripheral
        self.clock = clock
        self.diagnostic = diagnostic
        self.onFinish = onFinish
    }

    package func start() {
        deadline = Task { @BLECoreActor [weak self, clock] in
            do { try await clock.sleep(milliseconds: Deadlines.discovery) } catch { return }
            self?.finish(.failure(BLEFailure(
                code: .serviceDiscoveryTimeout,
                message: "\(Deadlines.discovery)ms 안에 서비스 탐색이 끝나지 않았다"
            )))
        }
        peripheral.discoverServices(nil)
    }

    /// 결과 없이 멈춘다. 멱등
    package func cancel() {
        onFinish = nil
        deadline?.cancel()
        deadline = nil
    }

    package func didDiscoverServices(_ services: [ServiceRef], error: PortError?) {
        guard onFinish != nil, !listed else { return }
        listed = true
        if let error {
            fail("서비스 탐색이 실패했다", error)
            return
        }
        guard !services.isEmpty else {
            fail("서비스가 하나도 없다", nil)
            return
        }
        var seen: [BLEUUID: Int] = [:]
        pending = services.map { portRef in
            let index = seen[portRef.uuid, default: 0]
            seen[portRef.uuid] = index + 1
            return PendingService(portRef: portRef, ref: ServiceRef(uuid: portRef.uuid, instanceIndex: index))
        }
        for service in pending { peripheral.discoverCharacteristics(nil, for: service.portRef) }
    }

    package func didDiscoverCharacteristics(_ characteristics: [DiscoveredCharacteristic], for service: ServiceRef, error: PortError?) {
        guard onFinish != nil, listed else { return }
        guard let position = pending.firstIndex(where: { $0.portRef == service && $0.characteristics == nil }) else { return }
        if let error {
            fail("characteristic 탐색이 실패했다", error)
            return
        }
        let owner = pending[position].ref
        pending[position].characteristics = indexed(characteristics, in: owner)
        guard pending.allSatisfy({ $0.characteristics != nil }) else { return }
        // 포트 참조가 겹친 characteristic(진단 있음)은 한 번만 묻고 같은 결과를 나눠 쓴다
        var targets: [CharacteristicRef] = []
        for service in pending {
            for characteristic in service.characteristics ?? [] {
                guard let port = portRefs[characteristic.ref], descriptorResults[port] == nil else { continue }
                descriptorResults[port] = .some(nil)
                targets.append(port)
            }
        }
        guard !targets.isEmpty else {
            finishWithDescriptors()
            return
        }
        for port in targets { peripheral.discoverDescriptors(for: port) }
    }

    package func didDiscoverDescriptors(_ descriptors: [DescriptorRef], for characteristic: CharacteristicRef, error: PortError?) {
        guard onFinish != nil, let slot = descriptorResults[characteristic], slot == nil else { return }
        if let error {
            fail("descriptor 탐색이 실패했다", error)
            return
        }
        descriptorResults[characteristic] = .some(descriptors)
        guard descriptorResults.values.allSatisfy({ $0 != nil }) else { return }
        finishWithDescriptors()
    }

    /// 공개 descriptor 참조는 공개 characteristic 참조 + 같은 UUID 사이의 탐색 순서다
    private func finishWithDescriptors() {
        finish(.success(pending.map { service in
            GATTService(ref: service.ref, characteristics: (service.characteristics ?? []).map { characteristic in
                var seen: [BLEUUID: Int] = [:]
                let found = portRefs[characteristic.ref].flatMap { descriptorResults[$0] ?? nil } ?? []
                let descriptors = found.map { port in
                    let index = seen[port.uuid, default: 0]
                    seen[port.uuid] = index + 1
                    let ref = DescriptorRef(characteristic: characteristic.ref, uuid: port.uuid, instanceIndex: index)
                    portDescriptorRefs[ref] = port
                    return ref
                }
                return GATTCharacteristic(ref: characteristic.ref, properties: characteristic.properties, descriptors: descriptors)
            })
        }))
    }

    /// 같은 UUID characteristic 은 탐색 순서대로 0, 1, … 을 받는다. 플랫폼이 준 참조끼리 같아 가릴 수 없었으면 진단을 남긴다
    private func indexed(_ found: [DiscoveredCharacteristic], in service: ServiceRef) -> [GATTCharacteristic] {
        if Set(found.map(\.ref)).count != found.count {
            diagnostic(.duplicateCharacteristicReference, "서비스 \(service.uuid) 의 characteristic 참조가 겹쳐 탐색 순서로 가른다")
        }
        var seen: [BLEUUID: Int] = [:]
        return found.map { item in
            let index = seen[item.ref.uuid, default: 0]
            seen[item.ref.uuid] = index + 1
            let ref = CharacteristicRef(service: service, uuid: item.ref.uuid, instanceIndex: index)
            portRefs[ref] = item.ref
            return GATTCharacteristic(ref: ref, properties: item.properties)
        }
    }

    private func fail(_ message: String, _ error: PortError?) {
        let detail = error.map { PlatformDetail(ios: .init(domain: $0.domain, code: $0.code)) }
        finish(.failure(BLEFailure(
            code: .serviceDiscoveryFailed,
            message: error.map { "\(message): \($0.message)" } ?? message,
            platformDetail: detail
        )))
    }

    private func finish(_ outcome: Outcome) {
        guard let callback = onFinish else { return }
        onFinish = nil
        deadline?.cancel()
        deadline = nil
        callback(outcome)
    }
}
