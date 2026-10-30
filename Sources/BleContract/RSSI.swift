import Foundation

// RSSI 호출 형식(CANDIDATE-34): `readRssi`(추가 키 없음)의 백엔드 입구와 결과 줄 `readRssi ok <dBm>`.
// Scenario.swift·ScenarioEngine.swift 는 baseline 400줄 초과라 따로 둔다

/// 백엔드의 RSSI 호출. `ScenarioBackend` 가 상속한다
public protocol RSSIBackend: Sendable {
    /// 연결된 기기의 RSSI 를 한 번 읽는다. 읽은 값은 `CallOutcome.rssiRead`로 돌려준다
    func readRssi() async throws -> CallOutcome
}

extension CallOutcome {
    /// `readRssi ok -58`(10진수 dBm)
    public static func rssiRead(_ dBm: Int) -> CallOutcome {
        .okWith(String(dBm))
    }
}
