import Foundation
import NucodeBleCore

// region guide:uuids
/// 예시 기기의 GATT 참조. Nordic UART Service(NUS) 기준이다. 실제 기기의 UUID 로 바꿔 쓴다
enum NUS {
    static let service = ServiceRef(uuid: BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
    /// 앱 → 기기 (write)
    static let rx = CharacteristicRef(service: service, uuid: BLEUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
    /// 기기 → 앱 (notify)
    static let tx = CharacteristicRef(service: service, uuid: BLEUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
}

/// 16비트 SIG UUID 는 4자리로 쓴다(Bluetooth base UUID 로 넓혀진다)
enum Battery {
    static let service = ServiceRef(uuid: BLEUUID(string: "180F")!, instanceIndex: 0)
    static let level = CharacteristicRef(service: service, uuid: BLEUUID(string: "2A19")!, instanceIndex: 0)
}
// endregion

// region guide:wait-ready
struct ReadyTimeout: Error {}

/// 세션이 `ready` 가 될 때까지 기다린다. 실패로 끝나면 그 `BLEError` 를, 시간이 지나면 `ReadyTimeout` 을 던진다.
/// `connect()` 의 정상 반환은 "시도가 시작됐다"는 뜻이라 이 대기가 필요하다
func waitUntilReady(_ session: any BLESession, timeout: Duration = .seconds(30)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await state in session.connectionStates {
                switch state {
                case .ready:
                    return
                case .disconnected(reason: .failed(let failure)):
                    throw BLEError(failure: failure)
                case .disconnected(reason: .requested), .disconnected(reason: .clientClosed):
                    throw CancellationError()
                default:
                    continue // connecting · discoveringServices · configuring · recovering · initial
                }
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ReadyTimeout()
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}
// endregion

func quickStart() async throws {
    // region guide:quick-start
    // 1. 앱당 하나 만들고 앱 수명 동안 둔다
    let client = BLEClient()
    client.start() // 이때 CBCentralManager 가 만들어지고 권한 팝업이 뜬다

    // 2. 스캔: 결과 스트림을 먼저 얻고 시작한다
    let results = client.scanResults
    try await client.startScan(request: ScanRequest(filter: ScanFilter(serviceUUIDs: [NUS.service.uuid])))
    var found: ScanResult?
    for await result in results {
        found = result
        break
    }
    await client.stopScan()
    guard let device = found else { return }

    // 3. 연결: connect 는 시도가 시작되면 반환한다. Ready 는 따로 기다린다
    let session = try await client.connect(device.peripheralID, options: ConnectOptions())
    try await waitUntilReady(session)

    // 4. 읽기 · 쓰기 · 알림
    let level = try await session.read(Battery.level)
    print("battery", level.first ?? 0)

    let receipt = try await session.write(NUS.rx, value: Data("hello".utf8), options: WriteOptions())
    print("sent", receipt.bytesCompleted, "bytes")

    let incoming = session.notifications(for: NUS.tx) // 구독 전에 받을 곳부터 연다
    try await session.subscribe(NUS.tx)
    for await value in incoming.prefix(3) {
        print("received", value as NSData)
    }

    // 5. 정리
    await session.disconnect()
    client.close()
    // endregion
}
