import Foundation

/// 공개 client. 만들 때는 `BLEClientFactory.make(options:)` 를 쓴다.
public protocol BLEClient: AnyObject, Sendable {
    /// `start()` 전에는 `unknown`
    var adapterStates: AsyncStream<AdapterState> { get }

    /// 스캔 결과. 구독한 뒤의 것만 받고, 256개가 쌓이면 오래된 것부터 버린다. `startScan` 전에 얻어 둔다
    var scanResults: AsyncStream<ScanResult> { get }

    /// `Idle` · `Scanning` · `Idle(Failed:<코드>)`. 구독하면 현재 값을 먼저 준다
    var scanStates: AsyncStream<ScanState> { get }

    /// 모든 기기의 연결 전이 · 탐색 결과 · 구독 복원 실패 · 진단(로그용). 구독한 뒤의 것만 받고, 256개가 쌓이면 오래된 것부터 버린다
    var events: AsyncStream<BLEEvent> { get }

    // MARK: 앱 시작 등록 (iOS 전용, `start()` 전에만. 뒤에 부르면 프로그래머 오류로 trap 한다)

    /// 기기를 등록한다. `poweredOn` 에서 `connect(options)` 와 같은 경로로 연결하고, 복원된 기기는 그 경로가 이어받는다
    func register(_ peripheralID: PeripheralID, options: ConnectOptions, subscribe: [CharacteristicRef])

    /// 스캔 복원 때 되살릴 조건. 등록하지 않으면 복원된 스캔은 멈춘다
    func registerScan(_ request: ScanRequest)

    /// 등록된 characteristic 의 알림을 세션 단계와 무관하게 `queue` 에서 받는다
    func onNotification(
        queue: DispatchQueue,
        _ handler: @escaping @Sendable (PeripheralID, CharacteristicRef, Data) -> Void
    )

    /// throw 하지 않는다. 사용 설명 키가 없으면 manager 를 만들지 않고 `unauthorized(canRequest: false)` 를 게시한다.
    func start()

    /// 스캔은 한 번에 하나다. 같은 요청이면 아무 일 없이 성공하고, 다른 요청이면 `SCAN_ALREADY_RUNNING` 을 던진다.
    /// 블루투스가 꺼져 끝나면 자동으로 다시 시작하지 않는다
    func startScan(request: ScanRequest) async throws

    /// 멱등. 여러 번 불러도 된다
    func stopScan() async

    /// 연결하지 않고 세션만 얻는다. 같은 ID 면 같은 상태를 보는 세션이다. 닫힌 client 에서만 `CLIENT_CLOSED` 를 던진다
    func session(for peripheralID: PeripheralID) throws -> any BLESession

    /// 세션을 만들고 연결 시도를 시작한다. 반환은 "시도가 시작됐다"는 뜻이다(contract/states.md §4)
    func connect(_ peripheralID: PeripheralID, options: ConnectOptions) async throws -> any BLESession

    /// 지금 상태를 한 번에 읽는다. `close()` 뒤에는 닫힌 순간의 스냅샷을 준다
    func snapshot() async -> ClientSnapshot

    /// client 를 끝낸다. 되살릴 수 없다. 끝나지 않은 세션은 `disconnected(.clientClosed)` 가 되고 모든 스트림이 끝난다
    func close()
}
