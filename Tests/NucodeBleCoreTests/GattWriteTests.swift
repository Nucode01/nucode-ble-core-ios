import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// write: 나누기, 흐름 제어, 영수증 (contract/states.md §8)
@BLECoreActor
final class GattWriteTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private func makeReady() async throws -> (DefaultBLEClient, FakeCentral, Session) {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        let session = client.runtime.registry.session(for: id)
        _ = try await client.connect(id, options: ConnectOptions(autoReconnect: false))
        let ready = await waitUntil {
            if case .ready = session.state.value { return true }
            return false
        }
        XCTAssertTrue(ready)
        return (client, central, session)
    }

    private func pattern(_ count: Int) -> Data {
        Data((0..<count).map { UInt8($0 % 256) })
    }

    func testSplitCutsIntoLimitSizedPieces() async {
        let pieces = WriteJob.split(pattern(45), limit: 20)
        XCTAssertEqual(pieces.map(\.count), [20, 20, 5])
        XCTAssertEqual(WriteJob.split(Data(), limit: 20).count, 1)
    }

    func testAutomaticWithResponseSplitsByPlatformMaximum() async throws {
        let (client, central, session) = try await makeReady()
        let rx = central.peripheral.characteristicRef("nus.rx")
        let receipt = try await session.write(rx, value: pattern(1100), options: WriteOptions(mode: .withResponse))
        XCTAssertEqual(receipt, WriteReceipt(bytesCompleted: 1100, chunksCompleted: 3, delivery: .remoteAcknowledged))
        XCTAssertEqual(central.peripheral.rxCheckLine, "1100 ok")
        client.close()
    }

    func testFixedChunkingCountsChunks() async throws {
        let (client, central, session) = try await makeReady()
        let rx = central.peripheral.characteristicRef("nus.rx")
        let receipt = try await session.write(rx, value: pattern(512), options: WriteOptions(mode: .withResponse, chunking: .fixed(20)))
        XCTAssertEqual(receipt.chunksCompleted, 26)
        XCTAssertEqual(central.peripheral.rxCheckLine, "512 ok")
        client.close()
    }

    func testDisabledAndFixedAboveMaximumSendNothing() async throws {
        let (client, central, session) = try await makeReady()
        let rx = central.peripheral.characteristicRef("nus.rx")
        for chunking in [WriteChunking.disabled, .fixed(600)] {
            do {
                _ = try await session.write(rx, value: pattern(1024), options: WriteOptions(mode: .withResponse, chunking: chunking))
                XCTFail("must fail")
            } catch let error as BLEError {
                XCTAssertEqual(error.failure.code, .payloadTooLarge)
            }
        }
        XCTAssertEqual(central.peripheral.rxCheckLine, "0 ok")
        client.close()
    }

    func testWithoutResponseFlowControlDeliversEverything() async throws {
        let (client, central, session) = try await makeReady()
        let rx = central.peripheral.characteristicRef("nus.rx")
        let receipt = try await session.write(rx, value: pattern(8192), options: WriteOptions(mode: .withoutResponse))
        XCTAssertEqual(receipt.delivery, .submittedToPlatform)
        XCTAssertEqual(receipt.chunksCompleted, 133)
        let done = await waitUntil { central.peripheral.rxReport.count == 8192 }
        XCTAssertTrue(done)
        XCTAssertTrue(central.peripheral.rxReport.ok)
        client.close()
    }

    // MARK: write 한도 (CANDIDATE-5, api-contract §write 한도 계약)

    func testChunkSizeFollowsChunkingAndLimit() async throws {
        XCTAssertEqual(try WriteJob.chunkSize(.automatic, valueCount: 1000, limit: 62), 62)
        XCTAssertEqual(try WriteJob.chunkSize(.disabled, valueCount: 62, limit: 62), 62)
        XCTAssertEqual(try WriteJob.chunkSize(.fixed(20), valueCount: 1000, limit: 62), 20)
        XCTAssertEqual(try WriteJob.chunkSize(.fixed(62), valueCount: 1000, limit: 62), 62)
        for (chunking, count) in [(WriteChunking.disabled, 63), (.fixed(63), 1000), (.fixed(0), 1000)] {
            XCTAssertThrowsError(try WriteJob.chunkSize(chunking, valueCount: count, limit: 62), "\(chunking)") { error in
                XCTAssertEqual((error as? BLEError)?.failure.code, .payloadTooLarge)
            }
        }
    }

    func testWriteLimitsAppearAtReadyAndClearAfterDisconnect() async throws {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        let handle = try client.session(for: id)
        let session = client.runtime.registry.session(for: id)
        let limits = handle.writeLimits
        let collected = Task { () -> [WriteLimits?] in
            var values: [WriteLimits?] = []
            for await value in limits {
                values.append(value)
                if values.count == 3 { break }
            }
            return values
        }
        // Ready 를 본 관찰자는 nil 이 아닌 값을 읽는다
        let states = session.state.subscribe()
        let sawLimitsAtReady = Task { @BLECoreActor in
            for await state in states {
                if case .ready = state { return session.writeLimitsFlow.value != nil }
            }
            return false
        }
        try await handle.connect(options: ConnectOptions(autoReconnect: false))
        let atReady = await sawLimitsAtReady.value
        XCTAssertTrue(atReady)
        XCTAssertEqual(session.writeLimitsFlow.value, WriteLimits(withResponse: 512, withoutResponse: 62))
        await handle.disconnect()
        let values = await collected.value
        XCTAssertEqual(values, [nil, WriteLimits(withResponse: 512, withoutResponse: 62), nil])
        XCTAssertNil(session.writeLimitsFlow.value)
        client.close()
    }

    func testWriteUsesWriteLimitsNotThePort() async throws {
        let (client, central, session) = try await makeReady()
        let rx = central.peripheral.characteristicRef("nus.rx")
        // 가짜 포트는 512 다. 포트에 다시 물으면 3조각 · 성공이 된다
        session.writeLimitsFlow.send(WriteLimits(withResponse: 100, withoutResponse: 62))
        let receipt = try await session.write(rx, value: pattern(1100), options: WriteOptions(mode: .withResponse))
        XCTAssertEqual(receipt.chunksCompleted, 11)
        do {
            _ = try await session.write(rx, value: pattern(400), options: WriteOptions(mode: .withResponse, chunking: .fixed(200)))
            XCTFail("must fail")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .payloadTooLarge)
        }
        client.close()
    }

    func testCloseWhileReadyEndsWriteLimitsWithNil() async throws {
        let (client, _, session) = try await makeReady()
        XCTAssertNotNil(session.writeLimitsFlow.value)
        client.close()
        XCTAssertNil(session.writeLimitsFlow.value)
        XCTAssertTrue(session.writeLimitsFlow.isClosed)
    }

    func testWriteBeforeReadyIsRejected() async throws {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        let session = client.runtime.registry.session(for: id)
        do {
            _ = try await session.write(central.peripheral.characteristicRef("nus.rx"), value: Data([1]), options: WriteOptions())
            XCTFail("must fail")
        } catch let error as BLEError {
            XCTAssertEqual(error.failure.code, .notReady, "연결 전: 세션이 Ready 가 아니다(states.md §5 진입 검사 3)")
        }
        client.close()
    }
}
