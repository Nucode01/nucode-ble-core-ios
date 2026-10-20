import Foundation

/// 기기 하나를 보는 가벼운 view. `BLEClient.connect` 나 `session(for:)` 로 얻는다. 한 세션의 명령은 부른 순서대로 하나씩 실행된다
public protocol BLESession: AnyObject, Sendable {
    /// 이 세션의 기기 ID
    var peripheralID: PeripheralID { get }
    /// 연결 상태. 구독하면 현재 값을 먼저 준다
    var connectionStates: AsyncStream<ConnectionState> { get }
    /// 마지막으로 탐색한 서비스 목록. 연결이 끊겨도 비우지 않는다(contract/states.md)
    var services: AsyncStream<[GATTService]> { get }
    /// 이 연결에서 CCCD 가 확인된 ref 집합. 연결이 없으면 빈다(CANDIDATE-7)
    var activeSubscriptions: AsyncStream<Set<CharacteristicRef>> { get }

    /// 연결 시도가 시작되면(OS 가 요청을 받으면) 반환한다. 반환은 "연결됐다"가 아니다(contract/states.md §4).
    func connect(options: ConnectOptions) async throws
    /// 멱등. 해제 정리가 끝나면 반환한다
    func disconnect() async

    /// Ready 에서만. 요청 뒤 처음 온 값을 돌려준다(구독 중이면 알림 값일 수 있다)
    func read(_ characteristic: CharacteristicRef) async throws -> Data
    /// Ready 에서만. 조각은 끊기지 않고 연달아 나간다. 나누기가 허용하지 않는 크기면 아무것도 보내지 않고 `PAYLOAD_TOO_LARGE`
    func write(_ characteristic: CharacteristicRef, value: Data, options: WriteOptions) async throws -> WriteReceipt
    /// CCCD 확인 뒤 반환한다. 이미 구독했어도 다시 쓰고 성공한다. 구독 의도는 재연결 때 복원된다
    func subscribe(_ characteristic: CharacteristicRef) async throws
    /// 구독 중 온 값 전부(iOS 는 read 응답도 한 번 더 올 수 있다). collector 가 0명이 돼도 구독은 남는다
    func notifications(for characteristic: CharacteristicRef) -> AsyncStream<Data>
    /// 멱등. 의도를 먼저 지우고 CCCD 해제는 best-effort 다
    func unsubscribe(_ characteristic: CharacteristicRef) async throws
}

/// 공개 `BLESession`: 상태 없는 ID 기반 view. core 상태는 `Session` 이 갖는다
final class SessionHandle: BLESession {
    let session: Session
    let runtime: BLERuntime

    init(session: Session, runtime: BLERuntime) {
        self.session = session
        self.runtime = runtime
    }

    var peripheralID: PeripheralID { session.peripheralID }

    var connectionStates: AsyncStream<ConnectionState> {
        runOnCore { [session] in session.state.subscribe() }
    }

    var services: AsyncStream<[GATTService]> {
        runOnCore { [session] in session.servicesFlow.subscribe() }
    }

    var activeSubscriptions: AsyncStream<Set<CharacteristicRef>> {
        runOnCore { [session] in session.activeSubscriptionsFlow.subscribe() }
    }

    func connect(options: ConnectOptions) async throws {
        try await runtime.connect(session, options: options)
    }

    func disconnect() async {
        await runtime.disconnect(session)
    }

    func read(_ characteristic: CharacteristicRef) async throws -> Data {
        try await session.read(characteristic)
    }

    func write(_ characteristic: CharacteristicRef, value: Data, options: WriteOptions) async throws -> WriteReceipt {
        try await session.write(characteristic, value: value, options: options)
    }

    func subscribe(_ characteristic: CharacteristicRef) async throws {
        try await session.subscribe(characteristic)
    }

    func notifications(for characteristic: CharacteristicRef) -> AsyncStream<Data> {
        runOnCore { [session] in session.notifications(for: characteristic) }
    }

    func unsubscribe(_ characteristic: CharacteristicRef) async throws {
        try await session.unsubscribe(characteristic)
    }
}
