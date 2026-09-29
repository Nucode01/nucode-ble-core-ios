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

    private struct InternalScan {
        let services: [BLEUUID]
        let onDiscover: @BLECoreActor (any PeripheralPort, AdvertisementData, Int) -> Void
    }

    private struct PlatformScan: Equatable {
        let services: [BLEUUID]?
        let allowDuplicates: Bool
    }

    private var central: (any CentralPort)?
    private var adapterIsReady = false
    private var userRequest: ScanRequest?
    private var internalScans: [UInt64: InternalScan] = [:]
    private var nextInternalID: UInt64 = 0
    private var applied: PlatformScan?
    /// 복원된 플랫폼 스캔이 돌고 있을 수 있다. 다음 합집합 판정 때 원하는 스캔으로 덮거나 멈춘다
    private var restoredPlatformScan = false
    private(set) package var isClosed = false

    package init() {}

    package var isUserScanning: Bool { userRequest != nil }
    package var request: ScanRequest? { userRequest }

    package func attach(_ central: any CentralPort, adapter: AdapterState) {
        self.central = central
        adapterChanged(adapter)
    }

    // MARK: 사용자 스캔

    /// 어댑터 판정과 닫힘 확인은 호출자가 이 호출 직전에 한다. 같은 요청은 무동작, 다른 요청은 `SCAN_ALREADY_RUNNING`.
    package func start(_ request: ScanRequest) throws {
        guard !isClosed else { throw BLEError(failure: BLEFailure(code: .clientClosed, message: "클라이언트가 닫혔다")) }
        if let running = userRequest {
            guard running == request else {
                throw BLEError(failure: BLEFailure(code: .scanAlreadyRunning, message: "다른 요청의 스캔이 이미 돈다"))
            }
            return
        }
        userRequest = request
        reconcile()
        states.send(.scanning)
    }

    /// 멱등. 실패로 끝난 상태에서 부르면 `Idle` 로 돌아간다.
    package func stop() {
        guard userRequest != nil else {
            if case .failed = states.value { states.send(.idle) }
            return
        }
        userRequest = nil
        reconcile()
        states.send(.idle)
    }

    // MARK: 복원

    /// 복원 콜백에서 부른다. 등록된 스캔이 있으면 원래 조건 전체로 다시 걸고, 없으면 복원된 스캔을 멈춘다.
    /// 어댑터가 아직 Ready 가 아니면 Ready 가 될 때 반영한다.
    package func restore(registered request: ScanRequest?) {
        guard !isClosed else { return }
        restoredPlatformScan = true
        if let request, userRequest == nil {
            userRequest = request
            states.send(.scanning)
        }
        reconcile()
    }

    // MARK: 내부 확보 스캔

    /// `services` 가 비면 모든 광고를 받는다. 결과는 `onDiscover` 로만 가고 공개 흐름에는 나가지 않는다.
    package func acquire(
        services: [BLEUUID],
        onDiscover: @escaping @BLECoreActor (any PeripheralPort, AdvertisementData, Int) -> Void
    ) -> InternalScanToken {
        let id = nextInternalID
        nextInternalID += 1
        internalScans[id] = InternalScan(services: services, onDiscover: onDiscover)
        reconcile()
        return InternalScanToken(id: id)
    }

    /// 멱등
    package func release(_ token: InternalScanToken) {
        guard internalScans.removeValue(forKey: token.id) != nil else { return }
        reconcile()
    }

    // MARK: 어댑터

    /// Ready 를 벗어나면(Unknown 포함) 사용자 스캔은 `Idle(Failed:SCAN_STOPPED_BY_ADAPTER)` 로 끝난다.
    /// 내부 스캔은 남고, Ready 로 돌아오면 플랫폼 스캔을 다시 시작한다.
    package func adapterChanged(_ state: AdapterState) {
        let ready = state == .ready
        guard ready != adapterIsReady || !ready else { return }
        adapterIsReady = ready
        if !ready {
            applied = nil
            if userRequest != nil {
                userRequest = nil
                states.send(.failed(BLEFailure(code: .scanStoppedByAdapter, message: "스캔 중 어댑터가 Ready 를 벗어났다")))
            }
        } else {
            reconcile()
        }
    }

    // MARK: 플랫폼 콜백

    package func didDiscover(_ peripheral: any PeripheralPort, advertisement: AdvertisementData, rssi: Int) {
        guard !isClosed else { return }
        if let request = userRequest, ScanMatcher.matches(request.filter, advertisement) {
            results.emit(ScanResult(peripheralID: peripheral.id, rssi: rssi, advertisement: advertisement))
        }
        for id in internalScans.keys.sorted() {
            guard let scan = internalScans[id] else { continue }
            if scan.services.isEmpty || scan.services.contains(where: advertisement.serviceUUIDs.contains) {
                scan.onDiscover(peripheral, advertisement, rssi)
            }
        }
    }

    // MARK: 닫기

    package func close() {
        guard !isClosed else { return }
        userRequest = nil
        internalScans.removeAll()
        reconcile()
        isClosed = true
        states.close()
        results.close()
    }

    // MARK: 합집합

    /// 참여자 중 하나라도 서비스 조건이 없으면 플랫폼 필터는 없다(`nil`). 아니면 서비스 UUID 의 합집합.
    /// AllowDuplicates 는 사용자 요청이 `lowLatency` 일 때만 켠다.
    private func desiredPlatformScan() -> PlatformScan? {
        var participants: [[BLEUUID]] = []
        if let userRequest { participants.append(userRequest.filter.serviceUUIDs) }
        participants += internalScans.keys.sorted().compactMap { internalScans[$0]?.services }
        guard !participants.isEmpty else { return nil }
        let services: [BLEUUID]?
        if participants.contains(where: \.isEmpty) {
            services = nil
        } else {
            var union: [BLEUUID] = []
            for uuid in participants.joined() where !union.contains(uuid) { union.append(uuid) }
            services = union
        }
        return PlatformScan(services: services, allowDuplicates: userRequest?.options.mode == .lowLatency)
    }

    private func reconcile() {
        guard let central, adapterIsReady else { return }
        let desired = desiredPlatformScan()
        guard desired != applied || restoredPlatformScan else { return }
        restoredPlatformScan = false
        applied = desired
        if let desired {
            central.scanForPeripherals(services: desired.services, allowDuplicates: desired.allowDuplicates)
        } else {
            central.stopScan()
        }
    }
}
