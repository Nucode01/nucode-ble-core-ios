import Foundation

// MARK: RSSI 읽기 (CANDIDATE-34, api-contract §RSSI 계약, states.md §8)
// Session.swift 는 baseline 400줄 초과라 따로 둔다. GATT 큐 밖이고 차례는 `RSSITurn` 이 갖는다

extension Session {
    /// 진입 검사 1~3 뒤 RSSI 차례에 접수한다. 작업 대기는 마지막 줄의 한 번뿐이다.
    /// 호출자가 취소돼도 차례는 플랫폼 결과나 기한까지 그대로다
    package func readRSSI() async throws -> Int {
        try await admitReady()
        let waiter = context.rssiTurn.request(peripheralID, owner: self, clock: context.clock) { [weak self] in
            self?.peripheral?.readRSSI()
        }
        return try await waiter.value()
    }

    /// 세대를 보지 않는다: 옛 링크의 늦은 결과도 차례를 놓아야 다음 요청이 나간다(받을 호출자는 해제 때 이미 끝났다)
    package func peripheralDidReadRSSI(_ candidate: any PeripheralPort, rssi: Int, error: PortError?) {
        guard candidate.id == peripheralID else { return }
        let result: Result<Int, BLEError> = error.map { .failure(BLEError(failure: GattFailure.status($0, operation: "readRSSI"))) } ?? .success(rssi)
        context.rssiTurn.didRead(peripheralID, result)
    }
}
