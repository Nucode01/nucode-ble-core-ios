import Foundation
import NucodeBleCore

// MARK: 가짜 기기의 RSSI (contract/README §sim 가짜 기기 RSSI 읽기, CANDIDATE-34)
// FakePeripheral.swift 가 400줄을 넘지 않게 따로 둔다
//
// - 요청에 연결 간격 하나(15ms) 뒤 `rssiValue`(기본 -50)로 답한다. write 조각과 따로 돈다(GATT 큐 밖).
// - 앞 요청에 답하기 전에 온 요청에는 답하지 않는다(Android 스택의 어댑터 RSSI 슬롯이 차 있을 때처럼).
// - 링크가 없으면 바로, 답하기 전에 끊기면 예약한 때에 오류로 답한다.
// - `answersRSSI` 가 false 면 요청을 세기만 하고 답하지 않는다. 대기 상태로 두지 않으므로 true 로 돌리면 다음 요청에 답한다.

extension FakePeripheral {
    package func readRSSI() {
        rssiRequests += 1
        guard answersRSSI, !rssiPending else { return }
        rssiPending = true
        let generation = linkGeneration
        let wasLinked = isLinked
        fakeAfter(self, clock: clock, milliseconds: wasLinked ? timing.connectionInterval : 0) { device in
            device.rssiPending = false
            guard wasLinked, device.isLinked, device.linkGeneration == generation else {
                device.delegate?.peripheral(device, didReadRSSI: 0, error: PortError(domain: "FakePeripheral", code: 6, message: "not connected"))
                return
            }
            device.delegate?.peripheral(device, didReadRSSI: device.rssiValue, error: device.rssiError)
        }
    }
}
