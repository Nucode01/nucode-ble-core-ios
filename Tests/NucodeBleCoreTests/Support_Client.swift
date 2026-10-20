import BleContract
import BleCoreFakes
import Foundation
@testable import NucodeBleCore
import XCTest

/// 어댑터 판정·클라이언트 수명 시험의 공통 부품. CoreBluetooth 는 건드리지 않고 가짜 central 만 쓴다.
enum ClientTestSupport {
    /// 계약 시간 1ms 를 실제 0.05ms 로 줄인다: 2000ms 상한이 100ms 실제 시간이다
    static let scale = 0.05

    static func realMilliseconds(_ contractMilliseconds: Int) -> Int {
        Int(Double(contractMilliseconds) * scale)
    }

    static let spec = FakeDeviceSpec(advertisedName: "fake", services: [], characteristics: [])

    static let environment = BLEEnvironment(hasBluetoothUsageDescription: true)

    @BLECoreActor
    static func makeCentral(
        state: CentralPortState = .poweredOn,
        authorization: PortAuthorization = .allowedAlways
    ) -> FakeCentral {
        FakeCentral(spec: spec, clock: ScaledClock(scale: scale), state: state, authorization: authorization)
    }

    static func makeClient(
        environment: BLEEnvironment = ClientTestSupport.environment,
        options: BLEOptions = BLEOptions(),
        central: @escaping @BLECoreActor @Sendable () -> any CentralPort
    ) -> DefaultBLEClient {
        DefaultBLEClient(options: options, environment: environment, clock: ScaledClock(scale: scale), centralFactory: central)
    }

    static func sleep(realMilliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(realMilliseconds))
    }

    /// 계약 폴더. `BLE_CONTRACT_DIR` 를 주지 않았고 `../contract` 도 없으면 시험을 건너뛴다
    static func contractDirectory(packageRoot: URL) throws -> ContractDirectory {
        if ContractDirectory.isAbsent(packageRoot: packageRoot) { throw XCTSkip("계약 폴더 없음") }
        return ContractDirectory.locate(packageRoot: packageRoot)
    }
}

/// 명령 판정 하나의 결과: 성공은 "ok", 실패는 실패 코드
@BLECoreActor
final class GateProbe {
    private(set) var result: String?
    private var task: Task<Void, Never>?

    init(_ runtime: BLERuntime) {
        task = Task { @BLECoreActor [self] in
            do {
                try await runtime.requireUsableAdapter()
                result = "ok"
            } catch let error as BLEError {
                result = error.failure.code.value
            } catch is CancellationError {
                result = "cancelled"
            } catch {
                result = "other"
            }
        }
    }

    func cancel() { task?.cancel() }

    /// 결과가 나올 때까지 기다린다(실제 시간 상한)
    func wait(realMilliseconds limit: Int = 2000) async -> String? {
        var waited = 0
        while result == nil, waited < limit {
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return result
    }
}
