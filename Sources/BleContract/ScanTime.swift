// 스캔 결과 시각 레인(CANDIDATE-36c): `scanTime`. 두 플랫폼 값 레인이다

/// `scanTime` 레인 값을 정하는 규칙. 시나리오 하나 동안 대상 기기의 결과 시각을 차례로 받는다.
/// `startScan` 에서 되돌리지 않는다(iOS 기본 모드는 중복을 합쳐 스캔 하나에 결과가 하나뿐일 수 있다)
public struct ScanTimeLane: Sendable, Equatable {
    /// 시작 값이자, 비교할 앞 결과가 아직 없을 때의 값
    public static let start = "none"

    private var previous: Int64?
    private var hasDiff = false
    private var sawPositive = false
    private var sawNegative = false

    public init() {}

    /// 지금까지의 레인 값: 차이 중 음수가 하나라도 있으면 `back`(이후 고정), 아니면 양수가 있으면 `ok`, 모두 0 이면 `flat`
    public var value: String {
        if sawNegative { return "back" }
        if sawPositive { return "ok" }
        return hasDiff ? "flat" : Self.start
    }

    /// 대상 기기 결과 하나의 시각(나노초)을 더하고 새 레인 값을 돌려준다
    public mutating func record(_ timestampNanos: Int64) -> String {
        if let previous {
            hasDiff = true
            if timestampNanos < previous { sawNegative = true }
            if timestampNanos > previous { sawPositive = true }
        }
        previous = timestampNanos
        return value
    }
}

extension ScenarioObserver {
    /// `scanTime` 레인. 대상 기기의 모든 결과를 본다(`found` 창과 무관하다)
    func scanTime(_ timestampNanos: Int64) {
        recorder.update(lane: .scanTime) { s in
            let entry = s.scanTime.record(timestampNanos)
            s.log.append(entry, to: .scanTime)
        }
    }
}
