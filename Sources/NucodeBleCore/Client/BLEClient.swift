import Foundation

/// 공개 client. 만들 때는 `BLEClientFactory.make(options:)` 를 쓴다.
public protocol BLEClient: AnyObject, Sendable {
    /// `start()` 전에는 `unknown`
    var adapterStates: AsyncStream<AdapterState> { get }

    var scanResults: AsyncStream<ScanResult> { get }

    /// `Idle` · `Scanning` · `Idle(Failed:<코드>)`. 구독하면 현재 값을 먼저 준다
    var scanStates: AsyncStream<ScanState> { get }

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

    func startScan(request: ScanRequest) async throws

    func stopScan() async

    func session(for peripheralID: PeripheralID) throws -> any BLESession

    /// 세션을 만들고 연결 시도를 시작한다. 반환은 "시도가 시작됐다"는 뜻이다(contract/states.md §4)
    func connect(_ peripheralID: PeripheralID, options: ConnectOptions) async throws -> any BLESession

    func snapshot() async -> ClientSnapshot

    func close()
}
