import Foundation

/// 내부 확보 스캔 하나를 가리키는 표. `BLEScanner.release` 에 돌려준다
package struct InternalScanToken: Hashable, Sendable {
    fileprivate let id: UInt64
}

/// 스캔의 유일한 주인(docs/v1/ios-design.md §5). CBCentralManager 의 스캔은 하나라, 사용자 스캔과
/// 내부 확보 스캔(`PeripheralResolver`, ios-06)의 합집합을 하나의 플랫폼 스캔으로 돌린다.
/// 내부 스캔은 공개 스캔 상태와 사용자 결과를 바꾸지 않는다(CANDIDATE-12).
///
/// 이름은 Foundation 의 `Scanner` 와 겹치지 않게 `BLEScanner` 로 둔다.
@BLECoreActor
package final class BLEScanner {
    package let states = StateBroadcaster<ScanState>(.idle)
    package let results = EventHub<ScanResult>()

    private typealias DiscoverHandler = @BLECoreActor (any PeripheralPort, AdvertisementData, Int) -> Void

    /// 광고 하나가 도착한 순간의 값. `deliverInternal` 이 이 값을 참여자에게 넘긴다
    private struct Discovery {
        let peripheral: any PeripheralPort
        let advertisement: AdvertisementData
        let rssi: Int
    }

    private var central: (any CentralPort)?
    /// 스캔 수명 상태의 유일한 주인. 대입은 `dispatch` 안에서만 한다
    private var core = ScanCore.State()
    /// 내부 참여자의 결과 전달 클로저(순서 없음, 순서는 Core 가 정한다)
    private var handlers: [UInt64: DiscoverHandler] = [:]

    package init() {}

    package var isClosed: Bool { ScanCore.isClosed(core) }
    package var isUserScanning: Bool { ScanCore.isUserScanning(core) }
    package var request: ScanRequest? { ScanCore.request(core) }

    package func attach(_ central: any CentralPort, adapter: AdapterState) {
        self.central = central
        dispatch(.attached(adapter: adapter))
    }

    // MARK: 사용자 스캔

    /// 어댑터 판정과 닫힘 확인은 호출자가 이 호출 직전에 한다. 같은 요청은 무동작, 다른 요청은 `SCAN_ALREADY_RUNNING`.
    package func start(_ request: ScanRequest) throws {
        if let failure = dispatch(.startRequested(request)) { throw BLEError(failure: failure) }
    }

    /// 멱등. 실패로 끝난 상태에서 부르면 `Idle` 로 돌아간다.
    package func stop() {
        dispatch(.stopRequested)
    }

    // MARK: 복원

    /// 복원 콜백에서 부른다. 등록된 스캔이 있으면 원래 조건 전체로 다시 걸고, 없으면 복원된 스캔을 멈춘다.
    /// 어댑터가 아직 Ready 가 아니면 Ready 가 될 때 반영한다.
    package func restore(registered request: ScanRequest?) {
        dispatch(.restored(registered: request))
    }

    // MARK: 내부 확보 스캔

    /// `services` 가 비면 모든 광고를 받는다. 결과는 `onDiscover` 로만 가고 공개 흐름에는 나가지 않는다.
    package func acquire(
        services: [BLEUUID],
        onDiscover: @escaping @BLECoreActor (any PeripheralPort, AdvertisementData, Int) -> Void
    ) -> InternalScanToken {
        let id = ScanCore.nextInternalID(core)
        handlers[id] = onDiscover
        dispatch(.internalJoined(services: services))
        return InternalScanToken(id: id)
    }

    /// 멱등
    package func release(_ token: InternalScanToken) {
        handlers.removeValue(forKey: token.id)
        dispatch(.internalLeft(token.id))
    }

    // MARK: 어댑터

    /// Ready 를 벗어나면(Unknown 포함) 사용자 스캔은 `Idle(Failed:SCAN_STOPPED_BY_ADAPTER)` 로 끝난다.
    /// 내부 스캔은 남고, Ready 로 돌아오면 플랫폼 스캔을 다시 시작한다.
    package func adapterChanged(_ state: AdapterState) {
        dispatch(.adapterChanged(state))
    }

    // MARK: 플랫폼 콜백

    package func didDiscover(_ peripheral: any PeripheralPort, advertisement: AdvertisementData, rssi: Int) {
        dispatch(.discovered(advertisement), discovery: Discovery(peripheral: peripheral, advertisement: advertisement, rssi: rssi))
    }

    // MARK: 닫기

    package func close() {
        handlers.removeAll()
        dispatch(.close)
    }

    // MARK: 사건 실행

    /// 사건을 Core 에 넘겨 새 상태를 먼저 저장하고, 할 일을 순서대로 실행한다.
    /// 시작이 거절되면 그 실패를 돌려준다.
    @discardableResult
    private func dispatch(_ event: ScanCore.Event, discovery: Discovery? = nil) -> BLEFailure? {
        let (next, effects) = ScanCore.step(core, event)
        core = next
        var rejection: BLEFailure?
        for effect in effects {
            if case .rejectStart(let failure) = effect {
                rejection = rejection ?? failure
            } else {
                perform(effect, discovery: discovery)
            }
        }
        return rejection
    }

    private func perform(_ effect: ScanCore.Effect, discovery: Discovery?) {
        switch effect {
        case .platformScan(let services, let allowDuplicates):
            central?.scanForPeripherals(services: services, allowDuplicates: allowDuplicates)
        case .platformStop:
            central?.stopScan()
        case .publish(let value):
            states.send(value)
        case .rejectStart:
            break
        case .emitResult:
            guard let discovery else { break }
            results.emit(ScanResult(peripheralID: discovery.peripheral.id, rssi: discovery.rssi, advertisement: discovery.advertisement))
        case .deliverInternal(let id):
            guard let discovery, let handler = handlers[id] else { break }
            handler(discovery.peripheral, discovery.advertisement, discovery.rssi)
        case .closeStreams:
            states.close()
            results.close()
        }
    }
}
