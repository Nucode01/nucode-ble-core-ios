import BleContract
import BleCoreFakes
import Foundation
import XCTest
@testable import NucodeBleCore

/// descriptor 탐색 · readDescriptor · writeDescriptor (CANDIDATE-32, api-contract §descriptor 계약, states.md §5 진입 검사 1~5).
/// 가짜 기기는 probe 정의를 쓴다: `probe.value` ccc·cpf, `probe.control` cud·echo, `nus.tx` ccc
@BLECoreActor
final class DescriptorCommandTests: XCTestCase {
    typealias Support = ClientTestSupport

    private static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private let id = FakeDeviceSpec.defaultID
    private let ccc = BLEUUID(string: "2902")!
    private let cud = BLEUUID(string: "2901")!
    private let cpf = BLEUUID(string: "2904")!
    private let echo = BLEUUID(string: "6e7a0004-5c3a-4b8e-9d1f-0a1b2c3d4e5f")!

    private func waitUntil(realMilliseconds limit: Int = 3000, _ condition: () -> Bool) async -> Bool {
        var waited = 0
        while waited < limit {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
            waited += 5
        }
        return condition()
    }

    private func isReady(_ session: Session) -> Bool {
        if case .ready = session.state.value { return true }
        return false
    }

    private func makeClient() throws -> (DefaultBLEClient, FakeCentral, Session) {
        let dir = try ClientTestSupport.contractDirectory(packageRoot: Self.packageRoot)
        let spec = try FakeDeviceSpec(profile: try dir.loadPeripheral(named: "probe"))
        let central = FakeCentral(spec: spec, clock: ScaledClock(scale: Support.scale))
        let client = Support.makeClient { central }
        client.start()
        return (client, central, client.runtime.registry.session(for: id))
    }

    private func makeReady() async throws -> (DefaultBLEClient, FakeCentral, Session) {
        let (client, central, session) = try makeClient()
        _ = try await client.connect(id, options: ConnectOptions())
        let ready = await waitUntil { isReady(session) }
        XCTAssertTrue(ready)
        return (client, central, session)
    }

    private func code(_ body: () async throws -> Void) async -> String {
        do {
            try await body()
            return "ok"
        } catch let error as BLEError {
            return error.failure.code.value
        } catch {
            return "other"
        }
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02X", $0) }.joined() }

    private func ref(_ central: FakeCentral, _ symbol: String) -> CharacteristicRef {
        central.peripheral.characteristicRef(symbol)
    }

    private func descriptor(_ central: FakeCentral, _ symbol: String, _ uuid: BLEUUID, _ index: Int = 0) -> DescriptorRef {
        DescriptorRef(characteristic: ref(central, symbol), uuid: uuid, instanceIndex: index)
    }

    // MARK: 탐색

    func testReadyServicesCarryDescriptorsInDefinitionOrder() async throws {
        let (client, central, session) = try await makeReady()
        let all = session.services.flatMap(\.characteristics)
        func descriptors(_ symbol: String) -> [DescriptorRef]? {
            all.first { $0.ref == ref(central, symbol) }?.descriptors
        }
        XCTAssertEqual(descriptors("probe.value"), [descriptor(central, "probe.value", ccc), descriptor(central, "probe.value", cpf)])
        XCTAssertEqual(descriptors("probe.control"), [descriptor(central, "probe.control", cud), descriptor(central, "probe.control", echo)])
        XCTAssertEqual(descriptors("nus.tx"), [descriptor(central, "nus.tx", ccc)])
        XCTAssertEqual(descriptors("nus.rx"), [])
        client.close()
    }

    // MARK: read · write

    func testReadAndWriteReturnRawBytes() async throws {
        let (client, central, session) = try await makeReady()
        let text = try await session.readDescriptor(descriptor(central, "probe.control", cud))
        XCTAssertEqual(String(decoding: text, as: UTF8.self), "probe control")
        let format = try await session.readDescriptor(descriptor(central, "probe.value", cpf))
        XCTAssertEqual(hex(format), "19000027010000")
        let target = descriptor(central, "probe.control", echo)
        let initial = try await session.readDescriptor(target)
        XCTAssertEqual(hex(initial), "00")
        try await session.writeDescriptor(target, Data([0xA5, 0x5A, 0x01]))
        let written = try await session.readDescriptor(target)
        XCTAssertEqual(hex(written), "A55A01")
        try await session.writeDescriptor(target, Data(repeating: 0x11, count: 512))
        let longest = try await session.readDescriptor(target)
        XCTAssertEqual(longest.count, 512, "512바이트는 보낸다")
        client.close()
    }

    func testCccdReadFollowsSubscription() async throws {
        let (client, central, session) = try await makeReady()
        let target = descriptor(central, "probe.value", ccc)
        let off = try await session.readDescriptor(target)
        XCTAssertEqual(hex(off), "0000")
        try await session.subscribe(ref(central, "probe.value"))
        let on = try await session.readDescriptor(target)
        XCTAssertEqual(hex(on), "0100")
        client.close()
    }

    /// 진입 검사 5: 플랫폼 호출 전에 거절한다. 구독 상태는 구독 전 · 구독 중 모두 그대로다
    func testCccdWriteIsRejectedBeforeThePlatform() async throws {
        let (client, central, session) = try await makeReady()
        let value = ref(central, "probe.value")
        let target = descriptor(central, "probe.value", ccc)
        var result = await code { try await session.writeDescriptor(target, Data([0x01, 0x00])) }
        XCTAssertEqual(result, "DESCRIPTOR_WRITE_NOT_ALLOWED")
        XCTAssertEqual(session.activeSubscriptionsFlow.value, [])
        try await session.subscribe(value)
        result = await code { try await session.writeDescriptor(target, Data([0x00, 0x00])) }
        XCTAssertEqual(result, "DESCRIPTOR_WRITE_NOT_ALLOWED")
        XCTAssertEqual(session.activeSubscriptionsFlow.value, [value])
        XCTAssertEqual(central.peripheral.descriptorWriteCalls, 0, "가짜 기기에 쓰기 요청이 닿지 않았다")
        let still = try await session.readDescriptor(target)
        XCTAssertEqual(hex(still), "0100")
        client.close()
    }

    // MARK: 진입 검사 순서

    func testEntryCheckOrder() async throws {
        let (client, central, session) = try makeClient()
        let cccd = descriptor(central, "probe.value", ccc)
        let target = descriptor(central, "probe.control", echo)
        let tooLong = Data(repeating: 0, count: 513)
        // 3: 연결 전은 NOT_READY. CCCD 라도 3 이 5 보다 먼저다
        var result = await code { _ = try await session.readDescriptor(target) }
        XCTAssertEqual(result, "NOT_READY")
        result = await code { try await session.writeDescriptor(cccd, Data([0x01, 0x00])) }
        XCTAssertEqual(result, "NOT_READY")
        _ = try await client.connect(id, options: ConnectOptions())
        _ = await waitUntil { isReady(session) }
        // 4: 없는 descriptor(UUID·instanceIndex), 없는 characteristic 의 descriptor. 크기 검사보다 먼저다
        let missing = [
            descriptor(central, "probe.control", ccc),
            descriptor(central, "probe.control", cud, 1),
            DescriptorRef(characteristic: CharacteristicRef(service: ref(central, "probe.control").service, uuid: BLEUUID(string: "abcd")!, instanceIndex: 0), uuid: cud),
        ]
        for missingRef in missing {
            result = await code { _ = try await session.readDescriptor(missingRef) }
            XCTAssertEqual(result, "CHARACTERISTIC_NOT_FOUND", "\(missingRef)")
            result = await code { try await session.writeDescriptor(missingRef, tooLong) }
            XCTAssertEqual(result, "CHARACTERISTIC_NOT_FOUND", "\(missingRef)")
        }
        // 5 가 크기 검사보다 먼저다
        result = await code { try await session.writeDescriptor(cccd, tooLong) }
        XCTAssertEqual(result, "DESCRIPTOR_WRITE_NOT_ALLOWED")
        result = await code { try await session.writeDescriptor(target, tooLong) }
        XCTAssertEqual(result, "PAYLOAD_TOO_LARGE")
        XCTAssertEqual(central.peripheral.descriptorWriteCalls, 0)
        // 2: 어댑터가 세션보다 먼저다
        central.setAdapter(.poweredOff)
        _ = await waitUntil { if case .disconnected = session.state.value { return true } else { return false } }
        result = await code { _ = try await session.readDescriptor(target) }
        XCTAssertEqual(result, "ADAPTER_UNAVAILABLE")
        result = await code { try await session.writeDescriptor(cccd, Data([0x01, 0x00])) }
        XCTAssertEqual(result, "ADAPTER_UNAVAILABLE")
        // 1: 닫힘
        client.close()
        result = await code { _ = try await session.readDescriptor(target) }
        XCTAssertEqual(result, "CLIENT_CLOSED")
        result = await code { try await session.writeDescriptor(target, Data([0x01])) }
        XCTAssertEqual(result, "CLIENT_CLOSED")
    }

    /// 접수된 작업은 끊김에 read 와 같이 `OPERATION_INVALIDATED` 로 끝난다
    func testLinkLossInvalidatesQueuedDescriptorRead() async throws {
        let (client, central, session) = try await makeReady()
        let target = descriptor(central, "probe.control", cud)
        // core 큐는 직렬이다: 먼저 넣은 Task 가 작업을 접수하고, 그 뒤 차례의 링크 끊기가 기기 응답(연결 간격 뒤)보다 먼저 온다
        let pending = Task { @BLECoreActor in await self.code { _ = try await session.readDescriptor(target) } }
        central.cancelPeripheralConnection(central.peripheral)
        let result = await pending.value
        XCTAssertEqual(result, "OPERATION_INVALIDATED")
        client.close()
    }

    // MARK: iOS 값 재인코딩 (B.7)

    /// async 로 둔다: 이 클래스는 @BLECoreActor 라 동기 시험은 XCTest 가 다른 스레드에서 불러 멈춘다
    func testDescriptorValueConversion() async {
        XCTAssertEqual(DescriptorValueConversion.bytes(NSNumber(value: 1)), Data([0x01, 0x00]))
        XCTAssertEqual(DescriptorValueConversion.bytes(NSNumber(value: 0x0302)), Data([0x02, 0x03]))
        XCTAssertEqual(DescriptorValueConversion.bytes(NSString(string: "probe")), Data("probe".utf8))
        XCTAssertEqual(DescriptorValueConversion.bytes(Data([0x19, 0x00])), Data([0x19, 0x00]))
        XCTAssertEqual(DescriptorValueConversion.bytes(NSData(data: Data([0x07]))), Data([0x07]))
        XCTAssertNil(DescriptorValueConversion.bytes(nil))
        XCTAssertNil(DescriptorValueConversion.bytes([1, 2]))
    }
}
