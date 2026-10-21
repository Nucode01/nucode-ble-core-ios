import BleContract
import BleContractBackend
import XCTest

/// `runsOn: device` + `platforms: ios` 시나리오를 실기기에서 돌려 `CONTRACT|ios|…` 줄을 print 한다(lab/run-device.sh 가 모은다).
/// 계약 폴더는 시험 번들 리소스 `Contract/` 다. 시나리오마다 새 클라이언트로 시작한다.
final class ContractDeviceTests: XCTestCase {
    private static var directory: ContractDirectory? {
        Bundle(for: ContractDeviceTests.self).url(forResource: "Contract", withExtension: nil)
            .map(ContractDirectory.init(url:))
    }

    func testDeviceScenarios() async throws {
        let directory = try XCTUnwrap(Self.directory, "시험 번들에 Contract 리소스가 없다(run-device.sh 로 복사한 뒤 생성)")
        let only = ProcessInfo.processInfo.environment["BLE_DEVICE_ONLY"]
            .map { $0.split(separator: ",").map(String.init) }
        var ran = 0
        for id in try directory.scenarioIds() {
            if let only, !only.contains(id) { continue }
            let scenario = try directory.loadScenario(id: id)
            guard scenario.runsOn.contains(.device), scenario.platforms.contains(.ios) else { continue }
            ran += 1
            let report: ScenarioReport
            do {
                let backend = try await DeviceBackend.make(scenario: scenario)
                report = await ScenarioEngine(backend: backend).run(scenario)
                await backend.tearDown()
            } catch {
                print("CONTRACT|ios|\(id)|verdict|FAIL|setup: \(error)")
                XCTFail("\(id): setup: \(error)")
                continue
            }
            print(report.lines().joined(separator: "\n"))
            if let pending = scenario.pendingIosSupport {
                // 클로저 형식만 쓴다. 클로저 없이 부르면 남은 시나리오의 실패까지 예상 실패가 된다
                XCTExpectFailure("iOS \(pending) 구현 전 draft") {
                    XCTAssertEqual(report.verdict, .pass, "\(id): \(report.verdict)")
                }
            } else {
                XCTAssertEqual(report.verdict, .pass, "\(id): \(report.verdict)")
            }
        }
        XCTAssertGreaterThan(ran, 0, "돌릴 device·ios 시나리오가 없다")
    }
}
