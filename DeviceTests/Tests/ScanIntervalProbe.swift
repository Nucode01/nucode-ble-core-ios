import Foundation
import NucodeBleCore
import XCTest

/// 측정 프로브(CANDIDATE-36c): 앞 화면 lowLatency(AllowDuplicates) 스캔 창 동안 BLE_LAB_TEST 결과 콜백 수와 간격을 잰다.
/// 자기 scheme ScanIntervalProbe 로만 돈다. 계약 실행(ContractDeviceTests scheme)의 시험 대상에는 이 파일이 없다.
/// 창 길이는 BLE_SCAN_PROBE_SECONDS(xcodebuild 에는 TEST_RUNNER_ 접두, 기본 10).
/// 기록 줄 `PROBE|ios|scanInterval|durationMs=…|count=…|peripherals=…|stamp…|arrival…`. 간격은 첫 기기 결과의
/// timestampNanos 차이(stamp)와 받은 시각 차이(arrival), ms.
final class ScanIntervalProbe: XCTestCase {
    func testScanInterval() async throws {
        let seconds = ProcessInfo.processInfo.environment["BLE_SCAN_PROBE_SECONDS"].flatMap(Int.init) ?? 10
        let client = BLEClientFactory.make()
        client.start()
        let clock = ContinuousClock()
        // startScan 전에 얻어야 처음 결과를 잃지 않는다
        let stream = client.scanResults
        let collector = Task { () -> [Entry] in
            var entries: [Entry] = []
            for await result in stream {
                entries.append(Entry(stamp: result.timestampNanos, arrival: clock.now, id: result.peripheralID.rawValue))
            }
            return entries
        }
        var window: (start: ContinuousClock.Instant, end: ContinuousClock.Instant)?
        do {
            let request = ScanRequest(filter: ScanFilter(namePrefix: "BLE_LAB_TEST"), options: ScanOptions(mode: .lowLatency))
            try await client.startScan(request: request)
            let start = clock.now
            try await Task.sleep(for: .seconds(seconds))
            await client.stopScan()
            window = (start, clock.now)
        } catch {
            client.close()
            _ = await collector.value
            throw error
        }
        client.close()
        let all = await collector.value
        let (start, end) = try XCTUnwrap(window)

        let inside = all.filter { $0.arrival >= start && $0.arrival <= end }
        let target = inside.filter { $0.id == inside.first?.id }
        let stampGaps = gaps(target.map { Double($0.stamp) / 1_000_000 })
        let arrivalGaps = gaps(target.map { milliseconds($0.arrival - start) })
        print("PROBE|ios|scanInterval|" + [
            "durationMs=\(seconds * 1000)",
            "count=\(target.count)",
            "peripherals=\(Set(inside.map(\.id)).count)",
            summary("stamp", stampGaps),
            summary("arrival", arrivalGaps),
        ].joined(separator: "|"))
        XCTAssertGreaterThan(target.count, 1, "BLE_LAB_TEST 결과가 둘 이상이어야 간격을 잰다")
    }

    private struct Entry: Sendable {
        let stamp: Int64
        let arrival: ContinuousClock.Instant
        let id: String
    }

    private func milliseconds(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }

    private func gaps(_ values: [Double]) -> [Double] {
        zip(values.dropFirst(), values).map { $0 - $1 }
    }

    /// 정렬한 간격의 min·median·p90·max(ms, 소수 3자리)와 0·음수 간격 수.
    private func summary(_ name: String, _ gaps: [Double]) -> String {
        guard !gaps.isEmpty else { return "\(name)Gaps=0" }
        let sorted = gaps.sorted()
        let n = sorted.count
        func ms(_ v: Double) -> String { String(format: "%.3f", v) }
        let median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
        return [
            "\(name)MinMs=\(ms(sorted[0]))",
            "\(name)MedianMs=\(ms(median))",
            "\(name)P90Ms=\(ms(sorted[Int(Double(n - 1) * 0.9)]))",
            "\(name)MaxMs=\(ms(sorted[n - 1]))",
            "\(name)ZeroGaps=\(gaps.filter { $0 == 0 }.count)",
            "\(name)NegGaps=\(gaps.filter { $0 < 0 }.count)",
        ].joined(separator: "|")
    }
}
