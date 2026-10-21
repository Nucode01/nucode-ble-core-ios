import BleContract
import BleContractBackend
import BleCoreFakes
import Foundation
import Testing
@testable import NucodeBleCore

/// `runsOn: sim` + `platforms: ios` 시나리오를 가짜 포트 위의 실제 라이브러리로 돌린다.
/// 시나리오마다 새 클라이언트를 쓰고, 엔진 시계·라이브러리 시계·가짜 지연은 같은 배율(`BLE_SIM_SCALE`, 기본 1)을 쓴다.
/// `BLE_SIM_ONLY`(쉼표 목록)가 있으면 그 시나리오만 돌린다. 목록에 대상이 아닌 id 가 있으면 실패한다.
enum SimContract {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let dir = ContractDirectory.locate(packageRoot: packageRoot)

    static let isAbsent = ContractDirectory.isAbsent(packageRoot: packageRoot)

    static var scale: Double {
        ProcessInfo.processInfo.environment["BLE_SIM_SCALE"].flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil } ?? 1
    }

    /// sim·ios 대상 시나리오 전부
    static let targetIds: [String] = {
        guard let ids = try? dir.scenarioIds() else { return [] }
        return ids.filter { id in
            guard let scenario = try? dir.loadScenario(id: id) else { return false }
            return scenario.runsOn.contains(.sim) && scenario.platforms.contains(.ios)
        }
    }()

    static var onlyList: [String]? {
        guard let raw = ProcessInfo.processInfo.environment["BLE_SIM_ONLY"], !raw.isEmpty else { return nil }
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// 이번 실행에서 돌릴 id
    static let selectedIds: [String] = {
        guard let only = onlyList else { return targetIds }
        return only.filter(targetIds.contains)
    }()

    static func portState(for value: AdapterValue) -> (CentralPortState, PortAuthorization) {
        switch value {
        case .unknown: (.unknown, .allowedAlways)
        case .ready: (.poweredOn, .allowedAlways)
        case .poweredOff: (.poweredOff, .allowedAlways)
        case .resetting: (.resetting, .allowedAlways)
        case .unsupported: (.unsupported, .allowedAlways)
        case .unauthorizedCanRequest: (.unauthorized, .notDetermined)
        case .unauthorizedDenied: (.unauthorized, .denied)
        }
    }

    static func run(id: String) async throws -> ScenarioReport {
        let scenario = try dir.loadScenario(id: id)
        let spec = try FakeDeviceSpec(profile: scenario.peripheral)
        let clock = ScaledClock(scale: scale)
        let central = runOnCore { FakeCentral(spec: spec, clock: clock) }
        let client = DefaultBLEClient(environment: BLEEnvironment(hasBluetoothUsageDescription: true), clock: clock) { central }
        client.start()
        let hooks = BackendHooks(
            deviceEvent: { event in
                switch event {
                case .linkDrop: await central.peripheral.linkDrop()
                case .linkDropHide(let ms): await central.peripheral.linkDropHide(milliseconds: ms)
                case .notify(let count): await central.peripheral.notify(count: count)
                case .readNotify(let on): await central.peripheral.readNotify(on: on)
                case .rxCheck: break
                }
            },
            rxCheck: { await central.peripheral.rxCheckLine },
            setAdapter: { value in
                let (state, authorization) = portState(for: value)
                await central.setAdapter(state, authorization: authorization)
            }
        )
        let backend = try ClientBackend(client: client, profile: scenario.peripheral, targetID: spec.id, hooks: hooks)
        return await ScenarioEngine(backend: backend, clock: .scaled(scale)).run(scenario)
    }
}

/// 계약 폴더가 없으면(`BLE_CONTRACT_DIR` 없음, `../contract` 없음) 건너뛴다
@Suite(.enabled(if: !SimContract.isAbsent, "계약 폴더 없음"))
struct ContractSimTests {
    @Test func onlyListNamesSimIosScenarios() {
        let unknown = (SimContract.onlyList ?? []).filter { !SimContract.targetIds.contains($0) }
        #expect(unknown.isEmpty, "BLE_SIM_ONLY 에 sim·ios 대상이 아닌 id: \(unknown)")
        #expect(!SimContract.targetIds.isEmpty, "계약 폴더에서 sim·ios 시나리오를 찾지 못했다")
    }

    @Test(arguments: SimContract.selectedIds)
    func scenarioPasses(id: String) async throws {
        let report = try await SimContract.run(id: id)
        print(report.lines().joined(separator: "\n"))
        guard try SimContract.dir.loadScenario(id: id).awaitsIosDescriptorSupport else {
            #expect(report.verdict == .pass, "\(id): \(report.verdict)")
            return
        }
        withKnownIssue("iOS descriptor 구현 전(CANDIDATE-32) draft") {
            #expect(report.verdict == .pass, "\(id): \(report.verdict)")
        }
    }
}
