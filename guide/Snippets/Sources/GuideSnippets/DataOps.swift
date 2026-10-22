import Foundation
import NucodeBleCore

func readExamples(_ session: any BLESession) async throws {
    // region guide:read
    let value = try await session.read(Battery.level)
    let percent = value.first.map(Int.init) ?? 0
    print("battery \(percent)%")
    // endregion
}

func writeExamples(_ session: any BLESession) async throws {
    // region guide:write
    // 기본값: 응답 있는 쓰기(.withResponse) + 자동 나누기(.automatic)
    let receipt = try await session.write(NUS.rx, value: Data("ping".utf8), options: WriteOptions())
    // receipt.delivery == .remoteAcknowledged: 기기가 받았다고 확인했다

    // 긴 값도 그대로 넘긴다. 한 번에 보낼 수 있는 크기로 잘라 연달아 보낸다
    let firmwareBlock = Data(repeating: 0xAB, count: 600)
    let long = try await session.write(NUS.rx, value: firmwareBlock, options: WriteOptions())
    print(long.bytesCompleted, "bytes in", long.chunksCompleted, "chunks")

    // 응답 없는 쓰기: 빠르지만 기기가 받았는지는 모른다(.submittedToPlatform)
    let fast = try await session.write(
        NUS.rx,
        value: Data(repeating: 0x00, count: 2000),
        options: WriteOptions(mode: .withoutResponse)
    )

    // 기기 프로토콜이 20바이트 조각을 요구하면 크기를 고정한다
    let fixed = try await session.write(NUS.rx, value: firmwareBlock, options: WriteOptions(chunking: .fixed(20)))

    // 나누면 안 되는 명령: 한 번에 못 보내는 크기면 아무것도 보내지 않고 PAYLOAD_TOO_LARGE
    let atomic = try await session.write(NUS.rx, value: Data([0x01, 0x02]), options: WriteOptions(chunking: .disabled))
    // endregion
    _ = (receipt, fast, fixed, atomic)
}

func subscribeExamples(_ session: any BLESession) async throws {
    // region guide:subscribe
    // 1. 받을 곳을 먼저 연다. 이 호출 뒤에 온 값은 놓치지 않는다
    let values = session.notifications(for: NUS.tx)
    // 2. 구독: 기기가 CCCD 를 받아들이면 반환한다
    try await session.subscribe(NUS.tx)
    // 3. 받기. 같은 characteristic 에 여러 곳이 notifications(for:) 를 열면 모두 같은 값을 받는다
    let reader = Task {
        for await value in values {
            print("notify", String(decoding: value, as: UTF8.self))
        }
    }

    // 그만 받을 때: unsubscribe 는 멱등이고 재연결 때 되살리지 않는다
    try await session.unsubscribe(NUS.tx)
    reader.cancel() // 스트림을 닫는 것은 수신 쪽의 몫이다. 구독 자체는 unsubscribe 로만 끝난다
    // endregion
}

// region guide:request-response
struct ResponseTimeout: Error {}

/// 명령을 쓰고 알림으로 오는 첫 응답을 기다린다. `NUS.tx` 는 미리 구독해 둔 상태를 전제한다
func request(_ command: Data, over session: any BLESession, timeout: Duration = .seconds(3)) async throws -> Data {
    let replies = session.notifications(for: NUS.tx) // 쓰기 전에 연다: 응답이 쓰기 완료보다 먼저 올 수 있다
    _ = try await session.write(NUS.rx, value: command, options: WriteOptions())
    return try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask {
            for await reply in replies { return reply }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ResponseTimeout()
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}
// endregion

func descriptorExamples(_ session: any BLESession, services: [GATTService]) async throws {
    // region guide:descriptors
    // 탐색 결과에 characteristic 마다 descriptor 가 탐색 순서대로 있다(Ready 시점에 채워져 있다)
    let userDescription = BLEUUID(string: "2901")!
    let descriptors = services.flatMap(\.characteristics).first { $0.ref == NUS.tx }?.descriptors ?? []
    if let cud = descriptors.first(where: { $0.uuid == userDescription }) {
        let name = try await session.readDescriptor(cud) // 원본 bytes. 0x2901 은 UTF-8 문자열이다
        print("user description:", String(decoding: name, as: UTF8.self))
    }

    // 참조는 값이라 직접 만들어도 된다. 같은 UUID 가 여럿이면 instanceIndex 로 고른다(기본 0)
    let vendor = DescriptorRef(characteristic: NUS.tx, uuid: BLEUUID(string: "6e7a0004-5c3a-4b8e-9d1f-0a1b2c3d4e5f")!)
    try await session.writeDescriptor(vendor, Data([0x01])) // 응답 있는 쓰기 한 번, 나누지 않는다

    // CCCD(0x2902)는 읽기만 한다. 쓰면 DESCRIPTOR_WRITE_NOT_ALLOWED. 구독은 subscribe · unsubscribe 로 바꾼다
    let cccd = DescriptorRef(characteristic: NUS.tx, uuid: BLEUUID(string: "2902")!)
    let state = try await session.readDescriptor(cccd) // 구독 중이면 [0x01, 0x00]
    // endregion
    _ = state
}

func activeSubscriptionsExample(_ session: any BLESession) {
    // region guide:active-subscriptions
    // 이 연결에서 기기가 실제로 켜 준 구독. 연결이 끊기면 빈 집합, 재연결 뒤 복원되면 다시 채워진다
    Task {
        for await active in session.activeSubscriptions {
            print("notify on:", active.contains(NUS.tx))
        }
    }
    // endregion
}
