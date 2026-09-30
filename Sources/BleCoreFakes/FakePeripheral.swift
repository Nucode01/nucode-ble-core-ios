import Foundation
import NucodeBleCore

/// contract/README §sim 의 가짜 기기(nRF52840 시험 펌웨어 흉내)와 그 CBPeripheral.
/// 링크·광고·GATT·수신 계수·기기 사건이 모두 여기 있다. 콜백은 모두 core 큐에서 나간다.
///
/// - 광고: 링크가 없고 숨김 중이 아닐 때만.
/// - connect: 기한 없이 기다리다 광고 중이면 붙는다. 이미 연결됐으면 `didConnect` 를 다시 낸다.
///   대기 connect 를 `cancelPeripheralConnection` 으로 취소하면 콜백이 없다(연결된 것만 `didDisconnect`).
/// - 쓰기 응답: PDU 마다 연결 간격 하나(15ms). `nus.rx` 는 PDU 가 도착할 때마다 세고 판정한다.
/// - 응답 없는 쓰기: 용량이 차면 `canSendWriteWithoutResponse` 가 false 가 되고 그때 쓴 값은 버려진다
///   (CoreBluetooth 와 같다). 다시 여유가 생기면 `peripheralIsReady`.
@BLECoreActor
package final class FakePeripheral: PeripheralPort {
    package let id: PeripheralID
    package var name: String? { spec.advertisedName }
    package weak var delegate: (any PeripheralPortDelegate)?
    package weak var central: FakeCentral?

    package var connectionState: PortPeripheralState {
        if linked { return .connected }
        return pendingConnect ? .connecting : .disconnected
    }

    package var canSendWriteWithoutResponse: Bool { transmitQueue.count < timing.transmitCapacity }

    /// 링크가 있다
    package var isLinked: Bool { linked }
    /// 링크가 없고 숨김 중이 아니다
    package var isAdvertising: Bool { !linked && !hidden }

    /// 이 연결에서 `nus.rx` 로 받은 바이트 수와 `k mod 256` 판정
    package var rxReport: (count: Int, ok: Bool) { (rxCount, rxOK) }
    /// `probe.control` 을 읽으면 오는 값과 같은 모양: `4096 ok`
    package var rxCheckLine: String { "\(rxCount) \(rxOK ? "ok" : "bad")" }

    private let spec: FakeDeviceSpec
    private let clock: any BLEClock
    package let timing: FakeTiming

    private var serviceRefs: [ServiceRef] = []
    private var characteristicRefs: [String: CharacteristicRef] = [:]
    private var characteristicSpecs: [CharacteristicRef: FakeCharacteristicSpec] = [:]

    private var linked = false
    private var hidden = false
    private var hideEpoch: UInt64 = 0
    private var pendingConnect = false
    private var attachScheduled = false
    /// 링크가 새로 생기거나 끊길 때마다 올라간다. 예약된 작업이 옛 링크의 것인지 가린다.
    private var linkGeneration: UInt64 = 0

    private var subscribed: Set<CharacteristicRef> = []
    private var readNotifyOn = false
    private var notificationSequence: UInt32 = 0

    private var rxCount = 0
    private var rxOK = true

    private struct PendingWrite {
        let characteristic: CharacteristicRef
        let data: Data
        var offset = 0
    }
    private var writeQueue: [PendingWrite] = []
    private var writing = false
    private var transmitQueue: [(characteristic: CharacteristicRef, data: Data)] = []
    private var transmitting = false
    private var readyOwed = false

    init(spec: FakeDeviceSpec, clock: any BLEClock, timing: FakeTiming) {
        self.spec = spec
        self.id = spec.id
        self.clock = clock
        self.timing = timing
        for service in spec.services {
            let ref = ServiceRef(uuid: service.uuid, instanceIndex: 0)
            if !serviceRefs.contains(ref) { serviceRefs.append(ref) }
        }
        for characteristic in spec.characteristics {
            let ref = CharacteristicRef(
                service: ServiceRef(uuid: characteristic.service, instanceIndex: 0),
                uuid: characteristic.uuid,
                instanceIndex: 0
            )
            characteristicRefs[characteristic.symbol] = ref
            characteristicSpecs[ref] = characteristic
        }
    }

    /// 기기 정의의 기호 이름(`nus.rx`)에 해당하는 참조. 없는 이름이면 trap.
    package func characteristicRef(_ symbol: String) -> CharacteristicRef {
        guard let ref = characteristicRefs[symbol] else { preconditionFailure("unknown characteristic \(symbol)") }
        return ref
    }

    // MARK: 링크 (FakeCentral 이 부른다)

    func connectRequested() {
        if linked {
            fakeEmit(self) { $0.central?.deliverDidConnect() }
            return
        }
        pendingConnect = true
        attachIfPossible()
    }

    func cancelRequested() {
        pendingConnect = false
        guard linked else { return }
        fakeEmit(self) { $0.dropLink(error: nil) }
    }

    /// 대기 connect 를 실패로 끝낸다(`didFailToConnect`). 대기가 없으면 무동작
    func failPendingConnect(error: PortError) {
        guard pendingConnect, !linked else { return }
        pendingConnect = false
        central?.deliverDidFailToConnect(error: error)
    }

    /// 대기 connect 가 있고 붙을 수 있으면 `attachDelay` 뒤에 붙는다
    func attachIfPossible() {
        guard canAttach, !attachScheduled else { return }
        attachScheduled = true
        fakeAfter(self, clock: clock, milliseconds: timing.attachDelay) { device in
            device.attachScheduled = false
            guard device.canAttach else { return }
            device.pendingConnect = false
            device.linked = true
            device.linkGeneration += 1
            device.rxCount = 0
            device.rxOK = true
            device.central?.deliverDidConnect()
        }
    }

    private var canAttach: Bool {
        pendingConnect && isAdvertising && central?.state == .poweredOn
    }

    /// 링크를 끊고 연결에 딸린 것(구독·read 알림·전송 중인 쓰기)을 버린다
    func dropLink(error: PortError?) {
        guard linked else { return }
        linked = false
        linkGeneration += 1
        subscribed = []
        readNotifyOn = false
        writeQueue = []
        writing = false
        transmitQueue = []
        transmitting = false
        readyOwed = false
        central?.deliverDidDisconnect(error: error)
        attachIfPossible()
    }

    // MARK: 기기 사건

    /// 300ms 뒤 기기가 링크를 끊는다(원격 사용자 종료). 곧 다시 광고한다.
    package func linkDrop() {
        let generation = linkGeneration
        fakeAfter(self, clock: clock, milliseconds: timing.deviceEventDelay) { device in
            guard device.linked, device.linkGeneration == generation else { return }
            device.dropLink(error: PortError(domain: "FakePeripheral", code: 7, message: "remote user terminated"))
        }
    }

    /// 300ms 뒤 링크를 끊고 그때부터 `milliseconds` 동안 광고하지 않는다
    package func linkDropHide(milliseconds: Int) {
        let generation = linkGeneration
        fakeAfter(self, clock: clock, milliseconds: timing.deviceEventDelay) { device in
            guard device.linked, device.linkGeneration == generation else { return }
            device.hidden = true
            device.hideEpoch += 1
            let epoch = device.hideEpoch
            device.dropLink(error: PortError(domain: "FakePeripheral", code: 7, message: "remote user terminated"))
            fakeAfter(device, clock: device.clock, milliseconds: milliseconds) { device in
                guard device.hideEpoch == epoch else { return }
                device.hidden = false
                device.attachIfPossible()
            }
        }
    }

    /// `probe.value` 알림 `count` 개를 연결 간격마다 하나씩 보낸다(구독 중일 때만 도착)
    package func notify(count: Int) {
        let generation = linkGeneration
        for index in 0..<max(0, count) {
            fakeAfter(self, clock: clock, milliseconds: index * timing.connectionInterval) { device in
                guard device.linkGeneration == generation else { return }
                device.deliverNotification()
            }
        }
    }

    /// 켜면 `probe.value` read 응답 직전에 알림 하나를 먼저 보낸다. 연결이 끊기면 꺼진다.
    package func readNotify(on: Bool) {
        readNotifyOn = on
    }

    private func deliverNotification() {
        guard linked, let ref = characteristicRefs["probe.value"], subscribed.contains(ref) else { return }
        delegate?.peripheral(self, didUpdateValue: nextSequenceValue(), for: ref, error: nil)
    }

    private func nextSequenceValue() -> Data {
        notificationSequence &+= 1
        return withUnsafeBytes(of: notificationSequence.bigEndian) { Data($0) }
    }

    // MARK: PeripheralPort

    package func discoverServices(_ serviceUUIDs: [BLEUUID]?) {
        respond { device in
            let services = device.serviceRefs.filter { serviceUUIDs?.contains($0.uuid) ?? true }
            device.delegate?.peripheral(device, didDiscoverServices: services, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didDiscoverServices: [], error: error)
        }
    }

    package func discoverCharacteristics(_ characteristicUUIDs: [BLEUUID]?, for service: ServiceRef) {
        respond { device in
            let found = device.spec.characteristics
                .filter { $0.service == service.uuid && (characteristicUUIDs?.contains($0.uuid) ?? true) }
                .map { device.characteristicRefs[$0.symbol]! }
            device.delegate?.peripheral(device, didDiscoverCharacteristics: found, for: service, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didDiscoverCharacteristics: [], for: service, error: error)
        }
    }

    package func readValue(for characteristic: CharacteristicRef) {
        let readable = characteristicSpecs[characteristic]?.properties.contains("read") ?? false
        guard readable else {
            reject(PortError(domain: "FakePeripheral", code: 2, message: "reading is not permitted")) { device, error in
                device.delegate?.peripheral(device, didUpdateValue: nil, for: characteristic, error: error)
            }
            return
        }
        respond { device in
            if device.readNotifyOn, let value = device.characteristicRefs["probe.value"], device.subscribed.contains(value) {
                device.deliverNotification()
            }
            device.delegate?.peripheral(device, didUpdateValue: device.readResponse(for: characteristic), for: characteristic, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didUpdateValue: nil, for: characteristic, error: error)
        }
    }

    private func readResponse(for characteristic: CharacteristicRef) -> Data {
        switch characteristicSpecs[characteristic]?.symbol {
        case "probe.value": return nextSequenceValue()
        case "probe.control": return Data(rxCheckLine.utf8)
        default: return Data()
        }
    }

    package func setNotifyValue(_ enabled: Bool, for characteristic: CharacteristicRef) {
        let notifies = characteristicSpecs[characteristic]?.properties.contains("notify") ?? false
        guard notifies else {
            reject(PortError(domain: "FakePeripheral", code: 3, message: "notification is not supported")) { device, error in
                device.delegate?.peripheral(device, didUpdateNotificationState: false, for: characteristic, error: error)
            }
            return
        }
        // 이미 그 상태여도 콜백을 다시 낸다
        respond { device in
            if enabled { device.subscribed.insert(characteristic) } else { device.subscribed.remove(characteristic) }
            device.delegate?.peripheral(device, didUpdateNotificationState: enabled, for: characteristic, error: nil)
        } failure: { device, error in
            device.delegate?.peripheral(device, didUpdateNotificationState: false, for: characteristic, error: error)
        }
    }

    package func maximumWriteValueLength(for type: WriteMode) -> Int {
        switch type {
        case .withoutResponse: return 62
        case .withResponse: return 512
        }
    }

    package func writeValue(_ data: Data, for characteristic: CharacteristicRef, type: WriteMode) {
        let properties = characteristicSpecs[characteristic]?.properties ?? []
        switch type {
        case .withResponse:
            guard linked, properties.contains("write"), data.count <= maximumWriteValueLength(for: .withResponse) else {
                reject(PortError(domain: "FakePeripheral", code: linked ? 3 : 6, message: "write is not permitted")) { device, error in
                    device.delegate?.peripheral(device, didWriteValueFor: characteristic, error: error)
                }
                return
            }
            writeQueue.append(PendingWrite(characteristic: characteristic, data: Data(data)))
            writeNextPDU()
        case .withoutResponse:
            // 링크가 없거나 용량이 찼거나 쓸 수 없는 값이면 오류 없이 버려진다
            guard linked, properties.contains("writeWithoutResponse"), data.count <= maximumWriteValueLength(for: .withoutResponse),
                  canSendWriteWithoutResponse else { return }
            transmitQueue.append((characteristic, Data(data)))
            if !canSendWriteWithoutResponse { readyOwed = true }
            transmitNext()
        }
    }

    // MARK: 쓰기 (응답 있음)

    private func writeNextPDU() {
        guard !writing, !writeQueue.isEmpty else { return }
        writing = true
        let generation = linkGeneration
        fakeAfter(self, clock: clock, milliseconds: timing.connectionInterval) { device in
            guard device.linked, device.linkGeneration == generation, !device.writeQueue.isEmpty else { return }
            var write = device.writeQueue[0]
            let remaining = write.data.count - write.offset
            let take = min(remaining, write.data.count <= device.timing.singlePDULimit ? remaining : device.timing.pduBytes)
            let start = write.data.startIndex + write.offset
            device.receive(write.data[start..<start + take], on: write.characteristic)
            write.offset += take
            device.writing = false
            if write.offset >= write.data.count {
                device.writeQueue.removeFirst()
                device.delegate?.peripheral(device, didWriteValueFor: write.characteristic, error: nil)
            } else {
                device.writeQueue[0] = write
            }
            device.writeNextPDU()
        }
    }

    // MARK: 쓰기 (응답 없음)

    private func transmitNext() {
        guard !transmitting, !transmitQueue.isEmpty else { return }
        transmitting = true
        let generation = linkGeneration
        fakeAfter(self, clock: clock, milliseconds: timing.transmitInterval) { device in
            guard device.linked, device.linkGeneration == generation, !device.transmitQueue.isEmpty else { return }
            let packet = device.transmitQueue.removeFirst()
            device.receive(packet.data, on: packet.characteristic)
            device.transmitting = false
            if device.readyOwed, device.canSendWriteWithoutResponse {
                device.readyOwed = false
                device.delegate?.peripheralIsReady(toSendWriteWithoutResponse: device)
            }
            device.transmitNext()
        }
    }

    // MARK: 수신

    /// `nus.rx` 로 받은 바이트를 세고, 누적 k 번째 바이트가 `k mod 256` 인지 본다. 다른 characteristic 은 세지 않는다.
    private func receive(_ bytes: Data, on characteristic: CharacteristicRef) {
        guard characteristicSpecs[characteristic]?.symbol == "nus.rx" else { return }
        for byte in bytes {
            if byte != UInt8(truncatingIfNeeded: rxCount) { rxOK = false }
            rxCount += 1
        }
    }

    // MARK: 응답

    /// 연결 간격 하나 뒤에 `success` 를 낸다. 링크가 없으면 바로 `failure`, 그 사이 끊기면 아무것도 내지 않는다.
    private func respond(
        _ success: @escaping @BLECoreActor (FakePeripheral) -> Void,
        failure: @escaping @BLECoreActor (FakePeripheral, PortError) -> Void
    ) {
        guard linked else {
            reject(PortError(domain: "FakePeripheral", code: 6, message: "not connected"), failure)
            return
        }
        let generation = linkGeneration
        fakeAfter(self, clock: clock, milliseconds: timing.connectionInterval) { device in
            guard device.linked, device.linkGeneration == generation else { return }
            success(device)
        }
    }

    /// 요청은 받았지만 기기가 거절한다: 연결 간격 하나 뒤에 `failure`
    private func reject(_ error: PortError, _ failure: @escaping @BLECoreActor (FakePeripheral, PortError) -> Void) {
        fakeAfter(self, clock: clock, milliseconds: linked ? timing.connectionInterval : 0) { failure($0, error) }
    }
}
