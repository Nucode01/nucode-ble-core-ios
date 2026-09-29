import Dispatch

/// 라이브러리 core 의 직렬 큐. actor 실행기와 CBCentralManager 가 이 큐 하나를 쓴다(docs/v1/ios-design.md §3).
package let bleCoreQueue = DispatchSerialQueue(label: "kr.co.nucode.ble.core")

@globalActor
package actor BLECoreActor {
    package static let shared = BLECoreActor()
    package nonisolated var unownedExecutor: UnownedSerialExecutor { bleCoreQueue.asUnownedSerialExecutor() }
}

extension BLECoreActor {
    /// MainActor.assumeIsolated 와 같은 방식이다. 현재 실행 위치가 이 actor 의 실행기인지 확인하고
    /// (아니면 즉시 크래시), @BLECoreActor 클로저를 동기로 부른다. CoreBluetooth delegate 콜백 입구용.
    package static func assumeIsolated<T: Sendable>(
        _ operation: @BLECoreActor () throws -> T,
        file: StaticString = #fileID,
        line: UInt = #line
    ) rethrows -> T {
        typealias YesActor = @BLECoreActor () throws -> T
        typealias NoActor = () throws -> T
        shared.preconditionIsolated(file: file, line: line)
        return try withoutActuallyEscaping(operation) { (fn: @escaping YesActor) throws -> T in
            let raw = unsafeBitCast(fn, to: NoActor.self)
            return try raw()
        }
    }
}
