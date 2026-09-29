import Foundation

/// 스캔 수명의 상태 기계(contract/states.md §7). `(상태, 사건) → (새 상태, 할 일 목록)` 순수 함수다.
/// 입출력·시간·스레드·플랫폼 타입을 쓰지 않는다. 사용자 스캔과 내부 확보 스캔의 합집합을 플랫폼 스캔 하나로 돌린다.
///
/// 할 일 순서: start 는 플랫폼 → publish, restore 는 publish → 플랫폼, close 는 플랫폼 → closeStreams,
/// discovered 는 emitResult → deliverInternal(id 오름차순).
package enum ScanCore {
    package typealias InternalID = UInt64

    /// 플랫폼에 건 스캔 하나. `services` 가 nil 이면 필터가 없다
    package struct PlatformScan: Equatable {
        package let services: [BLEUUID]?
        package let allowDuplicates: Bool
    }

    package struct Participant: Equatable {
        package let id: InternalID
        package let services: [BLEUUID]
    }

    package struct State {
        package fileprivate(set) var hasCentral = false
        package fileprivate(set) var adapterIsReady = false
        package fileprivate(set) var userRequest: ScanRequest?
        /// 내부 참여자(id 오름차순)
        package fileprivate(set) var internalScans: [Participant] = []
        package fileprivate(set) var nextInternalID: InternalID = 0
        package fileprivate(set) var applied: PlatformScan?
        /// 복원된 플랫폼 스캔이 돌고 있을 수 있다. 다음 합집합 판정 때 원하는 스캔으로 덮거나 멈춘다
        package fileprivate(set) var restoredPlatformScan = false
        /// 게시된 값
        package fileprivate(set) var phase: ScanState = .idle
        package fileprivate(set) var isClosed = false

        package init() {}
    }

    package enum Event {
        case attached(adapter: AdapterState)
        case startRequested(ScanRequest)
        case stopRequested
        case restored(registered: ScanRequest?)
        case internalJoined(services: [BLEUUID])
        case internalLeft(InternalID)
        case adapterChanged(AdapterState)
        case discovered(AdvertisementData)
        case close
    }

    package enum Effect {
        case platformScan(services: [BLEUUID]?, allowDuplicates: Bool)
        case platformStop
        case publish(ScanState)
        case rejectStart(BLEFailure)
        case emitResult
        case deliverInternal(InternalID)
        case closeStreams
    }

    // MARK: 질의

    package static func isUserScanning(_ state: State) -> Bool { state.userRequest != nil }
    package static func request(_ state: State) -> ScanRequest? { state.userRequest }
    /// 다음 `internalJoined` 가 받을 id
    package static func nextInternalID(_ state: State) -> InternalID { state.nextInternalID }
    package static func phase(_ state: State) -> ScanState { state.phase }
    package static func isClosed(_ state: State) -> Bool { state.isClosed }

    // MARK: 전이

    package static func step(_ state: State, _ event: Event) -> (State, [Effect]) {
        var next = state
        var effects: [Effect] = []
        switch event {
        case .attached(let adapter):
            next.hasCentral = true
            adapterChanged(&next, &effects, adapter)
        case .startRequested(let request):
            guard !next.isClosed else {
                effects.append(.rejectStart(BLEFailure(code: .clientClosed, message: "클라이언트가 닫혔다")))
                break
            }
            if let running = next.userRequest {
                if running != request {
                    effects.append(.rejectStart(BLEFailure(code: .scanAlreadyRunning, message: "다른 요청의 스캔이 이미 돈다")))
                }
                break
            }
            next.userRequest = request
            reconcile(&next, &effects)
            publish(&next, &effects, .scanning)
        case .stopRequested:
            guard !next.isClosed else { break }
            guard next.userRequest != nil else {
                if case .failed = next.phase { publish(&next, &effects, .idle) }
                break
            }
            next.userRequest = nil
            reconcile(&next, &effects)
            publish(&next, &effects, .idle)
        case .restored(let request):
            guard !next.isClosed else { break }
            next.restoredPlatformScan = true
            if let request, next.userRequest == nil {
                next.userRequest = request
                publish(&next, &effects, .scanning)
            }
            reconcile(&next, &effects)
        case .internalJoined(let services):
            let id = next.nextInternalID
            next.nextInternalID += 1
            next.internalScans.append(Participant(id: id, services: services))
            reconcile(&next, &effects)
        case .internalLeft(let id):
            guard let index = next.internalScans.firstIndex(where: { $0.id == id }) else { break }
            next.internalScans.remove(at: index)
            reconcile(&next, &effects)
        case .adapterChanged(let adapter):
            adapterChanged(&next, &effects, adapter)
        case .discovered(let advertisement):
            guard !next.isClosed else { break }
            if let request = next.userRequest, ScanMatcher.matches(request.filter, advertisement) {
                effects.append(.emitResult)
            }
            for scan in next.internalScans {
                if scan.services.isEmpty || scan.services.contains(where: advertisement.serviceUUIDs.contains) {
                    effects.append(.deliverInternal(scan.id))
                }
            }
        case .close:
            guard !next.isClosed else { break }
            next.userRequest = nil
            next.internalScans.removeAll()
            reconcile(&next, &effects)
            next.isClosed = true
            effects.append(.closeStreams)
        }
        return (next, effects)
    }

    // MARK: 내부

    private static func publish(_ state: inout State, _ effects: inout [Effect], _ value: ScanState) {
        state.phase = value
        effects.append(.publish(value))
    }

    /// Ready 를 벗어나면(Unknown 포함) 사용자 스캔은 `Failed(SCAN_STOPPED_BY_ADAPTER)` 로 끝난다.
    /// 플랫폼 stopScan 은 부르지 않는다. 내부 스캔은 남고, Ready 로 돌아오면 플랫폼 스캔을 다시 건다.
    private static func adapterChanged(_ state: inout State, _ effects: inout [Effect], _ adapter: AdapterState) {
        let ready = adapter == .ready
        guard ready != state.adapterIsReady || !ready else { return }
        state.adapterIsReady = ready
        if !ready {
            state.applied = nil
            if state.userRequest != nil {
                state.userRequest = nil
                publish(&state, &effects, .failed(BLEFailure(code: .scanStoppedByAdapter, message: "스캔 중 어댑터가 Ready 를 벗어났다")))
            }
        } else {
            reconcile(&state, &effects)
        }
    }

    /// 참여자 중 하나라도 서비스 조건이 없으면 플랫폼 필터는 없다(`nil`). 아니면 서비스 UUID 의 합집합.
    /// AllowDuplicates 는 사용자 요청이 `lowLatency` 일 때만 켠다.
    private static func desiredPlatformScan(_ state: State) -> PlatformScan? {
        var participants: [[BLEUUID]] = []
        if let request = state.userRequest { participants.append(request.filter.serviceUUIDs) }
        participants += state.internalScans.map(\.services)
        guard !participants.isEmpty else { return nil }
        let services: [BLEUUID]?
        if participants.contains(where: \.isEmpty) {
            services = nil
        } else {
            var union: [BLEUUID] = []
            for uuid in participants.joined() where !union.contains(uuid) { union.append(uuid) }
            services = union
        }
        return PlatformScan(services: services, allowDuplicates: state.userRequest?.options.mode == .lowLatency)
    }

    private static func reconcile(_ state: inout State, _ effects: inout [Effect]) {
        guard state.hasCentral, state.adapterIsReady else { return }
        let desired = desiredPlatformScan(state)
        guard desired != state.applied || state.restoredPlatformScan else { return }
        state.restoredPlatformScan = false
        state.applied = desired
        if let desired {
            effects.append(.platformScan(services: desired.services, allowDuplicates: desired.allowDuplicates))
        } else {
            effects.append(.platformStop)
        }
    }
}
