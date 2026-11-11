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
        clock: any BLEClock = ScaledClock(scale: scale),
        central: @escaping @BLECoreActor @Sendable () -> any CentralPort
    ) -> DefaultBLEClient {
        DefaultBLEClient(options: options, environment: environment, clock: clock, centralFactory: central)
    }

    static func sleep(realMilliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(realMilliseconds))
    }

    /// 조건이 참이 될 때까지 기다린다(실제 시간 상한: 멈춤 방지용이고 판정 기준이 아니다)
    @BLECoreActor
    static func waitUntil(realMilliseconds limit: Int = 2000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    /// BLECoreActor 에 쌓인 일을 돌린다. 음성 확인 앞에 둔다
    @BLECoreActor
    static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// 계약 폴더. `BLE_CONTRACT_DIR` 를 주지 않았고 `../contract` 도 없으면 시험을 건너뛴다
    static func contractDirectory(packageRoot: URL) throws -> ContractDirectory {
        if ContractDirectory.isAbsent(packageRoot: packageRoot) { throw XCTSkip("계약 폴더 없음") }
        return ContractDirectory.locate(packageRoot: packageRoot)
    }
}

/// 시험이 시간을 직접 옮기는 시계. `advance` 하지 않으면 기한이 울리지 않는다
final class VirtualClock: BLEClock, @unchecked Sendable {
    private struct Sleeper {
        let id: UInt64
        let wake: Int
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var nanos: Int64 = 0
    /// 밀리초 시각. 나노초에서 내림으로 얻는다
    private var now: Int { Int(nanos / 1_000_000) }
    private var lastID: UInt64 = 0
    private var pending: [Sleeper] = []
    /// 등록 전에 취소된 sleep
    private var cancelledEarly: Set<UInt64> = []

    /// 지금 잠든 sleep 수
    var sleepers: Int { lock.withLock { pending.count } }

    func nowMilliseconds() -> Int { lock.withLock { now } }

    func nowNanoseconds() -> Int64 { lock.withLock { nanos } }

    func sleep(milliseconds: Int) async throws {
        let id = lock.withLock { lastID += 1; return lastID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let early = lock.withLock {
                    if cancelledEarly.remove(id) != nil { return true }
                    pending.append(Sleeper(id: id, wake: now + max(0, milliseconds), continuation: continuation))
                    return false
                }
                if early { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let sleeper = lock.withLock { () -> Sleeper? in
                guard let index = pending.firstIndex(where: { $0.id == id }) else {
                    cancelledEarly.insert(id)
                    return nil
                }
                return pending.remove(at: index)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// 시간을 `milliseconds` 옮기고 깰 시각이 된 sleep 을 깰 시각 순서로 깨운다
    func advance(by milliseconds: Int) {
        advance(nanoseconds: Int64(milliseconds) * 1_000_000)
    }

    /// 시간을 나노초로 옮긴다. 1ms 아래 해상도가 필요한 시험(스캔 결과 시각)에 쓴다
    func advance(nanoseconds: Int64) {
        let due = lock.withLock { () -> [Sleeper] in
            nanos += nanoseconds
            let due = pending.filter { $0.wake <= now }.sorted { $0.wake < $1.wake }
            pending.removeAll { $0.wake <= now }
            return due
        }
        for sleeper in due { sleeper.continuation.resume() }
    }

    /// 잠든 sleep 이 `count` 개가 될 때까지 기다린다(준비 대기, 실제 시간 상한 2초)
    func waitForSleepers(_ count: Int) async -> Bool {
        for _ in 0..<400 {
            if sleepers == count { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return sleepers == count
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
