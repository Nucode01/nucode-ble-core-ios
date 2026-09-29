import BleContract
import Foundation

enum Contract {
    /// Tests/BleContractTests/<파일> 에서 세 단계 위가 패키지 루트
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let dir = ContractDirectory.locate(packageRoot: packageRoot)

    static func probe() throws -> PeripheralProfile {
        try dir.loadPeripheral(named: "probe")
    }

    /// 인라인 시나리오. id 는 "inline"
    static func scenario(_ json: String) throws -> Scenario {
        let probe = try probe()
        return try Scenario.parse(Data(json.utf8), expectedId: "inline") { name in
            guard name == "probe" else { throw ContractError("no peripheral \(name)") }
            return probe
        }
    }
}
