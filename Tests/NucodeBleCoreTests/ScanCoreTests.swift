import XCTest
import NucodeBleCore

/// 스캔 수명 상태 기계 표 시험(contract/states.md §7, 행 id 는 .plans/refactor-R5-*.md 의 S01~S15).
/// 공개 타입에 `Equatable` 이 없어 할 일과 실패를 표기 문자열로 비교한다.
final class ScanCoreTests: XCTestCase {
    typealias Core = ScanCore

    private static let uuidA = BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!
    private static let uuidB = BLEUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")!

    private let a = ScanCoreTests.uuidA
    private let b = ScanCoreTests.uuidB

    private let alreadyRunning = "SCAN_ALREADY_RUNNING \"다른 요청의 스캔이 이미 돈다\""
    private let stopped = "SCAN_STOPPED_BY_ADAPTER \"스캔 중 어댑터가 Ready 를 벗어났다\""
    private let closed = "CLIENT_CLOSED \"클라이언트가 닫혔다\""

    private func req(_ services: [BLEUUID] = [], mode: ScanMode = .balanced, name: String? = nil) -> ScanRequest {
        ScanRequest(filter: ScanFilter(serviceUUIDs: services, namePrefix: name), options: ScanOptions(mode: mode))
    }

    // MARK: 표기

    private func label(_ uuid: BLEUUID) -> String { uuid == a ? "A" : uuid == b ? "B" : "?" }

    private func labels(_ services: [BLEUUID]?) -> String {
        services.map { "[" + $0.map(label).joined(separator: ",") + "]" } ?? "nil"
    }

    private func name(_ failure: BLEFailure) -> String { "\(failure.code.value) \"\(failure.message)\"" }

    private func name(_ phase: ScanState) -> String {
        switch phase {
        case .idle: "Idle"
        case .scanning: "Scanning"
        case .failed(let failure): "Failed:\(name(failure))"
        }
    }

    private func name(_ effect: Core.Effect) -> String {
        switch effect {
        case .platformScan(let services, let dup): "scan(\(labels(services)),dup=\(dup))"
        case .platformStop: "stop"
        case .publish(let phase): "publish(\(name(phase)))"
        case .rejectStart(let failure): "reject(\(name(failure)))"
        case .emitResult: "emit"
        case .deliverInternal(let id): "deliver(\(id))"
        case .closeStreams: "closeStreams"
        }
    }

    /// 사건을 차례로 넣고 마지막 상태와 사건별 할 일을 돌려준다
    private func run(_ start: Core.State, _ events: [Core.Event]) -> (Core.State, [[String]]) {
        var state = start
        var all: [[String]] = []
        for event in events {
            let (next, effects) = Core.step(state, event)
            state = next
            all.append(effects.map(name))
        }
        return (state, all)
    }

    private func ready(_ events: [Core.Event] = []) -> Core.State {
        run(Core.State(), [.attached(adapter: .ready)] + events).0
    }

    private func adv(_ services: [BLEUUID] = [], name: String? = nil) -> AdvertisementData {
        AdvertisementData(localName: name, serviceUUIDs: Set(services))
    }

    // MARK: 시작·멈춤

    func testS01_S02_S03_S04_startAndStop() {
        let s0 = Core.State()
        XCTAssertEqual(name(Core.phase(s0)), "Idle", "S01")
        XCTAssertFalse(Core.isUserScanning(s0), "S01")
        XCTAssertNil(Core.request(s0), "S01")

        var (state, out) = run(ready(), [.startRequested(req([a]))])
        XCTAssertEqual(out, [["scan([A],dup=false)", "publish(Scanning)"]], "S02")
        XCTAssertEqual(run(ready(), [.startRequested(req([a], mode: .lowLatency))]).1,
                       [["scan([A],dup=true)", "publish(Scanning)"]], "S02")
        XCTAssertEqual(run(ready(), [.startRequested(req())]).1,
                       [["scan(nil,dup=false)", "publish(Scanning)"]], "S02")

        (state, out) = run(state, [.startRequested(req([a])), .startRequested(req([b]))])
        XCTAssertEqual(out, [[], ["reject(\(alreadyRunning))"]], "S03")
        XCTAssertEqual(Core.request(state), req([a]), "S03")
        XCTAssertEqual(name(Core.phase(state)), "Scanning", "S03")

        (state, out) = run(state, [.stopRequested, .stopRequested])
        XCTAssertEqual(out, [["stop", "publish(Idle)"], []], "S04")

        let failed = run(ready([.startRequested(req([a])), .adapterChanged(.poweredOff)]), [.stopRequested])
        XCTAssertEqual(failed.1, [["publish(Idle)"]], "S04")
        XCTAssertEqual(name(Core.phase(failed.0)), "Idle", "S04")
    }

    // MARK: 합집합

    func testS05_S06_union() {
        let scanning = ready([.startRequested(req([a]))])
        var (state, out) = run(scanning, [
            .internalJoined(services: [b]), .internalJoined(services: []), .internalLeft(1), .internalLeft(1), .internalLeft(0),
        ])
        XCTAssertEqual(out, [
            ["scan([A,B],dup=false)"], ["scan(nil,dup=false)"], ["scan([A,B],dup=false)"], [], ["scan([A],dup=false)"],
        ], "S05")

        state = scanning
        (_, out) = run(state, [.internalJoined(services: [a]), .internalJoined(services: [b, a])])
        XCTAssertEqual(out, [[], ["scan([A,B],dup=false)"]], "S05 같은 조건이면 할 일 없음, 중복은 첫 순서로 한 번")

        let internalOnly = run(ready(), [.internalJoined(services: [])])
        XCTAssertEqual(internalOnly.1, [["scan(nil,dup=false)"]], "S06")
        (state, out) = run(internalOnly.0, [.startRequested(req([a], mode: .lowLatency)), .stopRequested, .internalLeft(0)])
        XCTAssertEqual(out, [["scan(nil,dup=true)", "publish(Scanning)"], ["scan(nil,dup=false)", "publish(Idle)"], ["stop"]], "S06")
    }

    // MARK: 어댑터

    func testS07_S08_adapter() {
        for gone in [AdapterState.poweredOff, .resetting, .unknown, .unauthorized(canRequest: true)] {
            let (state, out) = run(ready([.startRequested(req([a]))]), [.adapterChanged(gone), .adapterChanged(.poweredOff), .adapterChanged(.resetting)])
            XCTAssertEqual(out, [["publish(Failed:\(stopped))"], [], []], "S07 \(gone)")
            XCTAssertFalse(Core.isUserScanning(state), "S07")
        }

        let away = ready([.internalJoined(services: [b]), .adapterChanged(.poweredOff)])
        XCTAssertEqual(run(away, [.adapterChanged(.ready)]).1, [["scan([B],dup=false)"]], "S08")
        XCTAssertEqual(run(ready(), [.adapterChanged(.poweredOff), .adapterChanged(.ready)]).1, [[], []], "S08")
        XCTAssertEqual(run(ready([.internalJoined(services: [b])]), [.adapterChanged(.ready)]).1, [[]], "S08")
    }

    func testS09_beforeAttachOrReady() {
        let (state, out) = run(Core.State(), [
            .internalJoined(services: [b]), .startRequested(req([a])), .attached(adapter: .ready),
        ])
        XCTAssertEqual(out, [[], ["publish(Scanning)"], ["scan([A,B],dup=false)"]], "S09")
        XCTAssertEqual(name(Core.phase(state)), "Scanning", "S09")

        let off = run(Core.State(), [.startRequested(req([a])), .attached(adapter: .poweredOff)])
        XCTAssertEqual(off.1, [["publish(Scanning)"], ["publish(Failed:\(stopped))"]], "S09")
    }

    // MARK: 결과

    func testS10_results() {
        let scanning = ready([.startRequested(req([a]))])
        XCTAssertEqual(run(scanning, [.discovered(adv([a])), .discovered(adv([b]))]).1, [["emit"], []], "S10")

        let both = run(scanning, [.internalJoined(services: [b]), .internalJoined(services: [])]).0
        XCTAssertEqual(run(both, [.discovered(adv([b]))]).1, [["deliver(0)", "deliver(1)"]], "S10")
        XCTAssertEqual(run(both, [.discovered(adv([a]))]).1, [["emit", "deliver(1)"]], "S10")

        let internalOnly = ready([.internalJoined(services: [b])])
        XCTAssertEqual(run(internalOnly, [.discovered(adv([b])), .discovered(adv([a]))]).1, [["deliver(0)"], []], "S10")

        let named = ready([.startRequested(req(name: "Nx"))])
        XCTAssertEqual(run(named, [.discovered(adv()), .discovered(adv(name: "Nx-1")), .discovered(adv(name: "zz"))]).1,
                       [[], ["emit"], []], "S10")
    }

    // MARK: 복원

    func testS11_restoration() {
        XCTAssertEqual(run(ready(), [.restored(registered: req([a]))]).1,
                       [["publish(Scanning)", "scan([A],dup=false)"]], "S11")

        let again = run(ready([.startRequested(req([a]))]), [.restored(registered: req([a])), .restored(registered: req([a]))])
        XCTAssertEqual(again.1, [["scan([A],dup=false)"], ["scan([A],dup=false)"]], "S11 복원 뒤 한 번은 다시 건다")

        XCTAssertEqual(run(ready(), [.restored(registered: nil)]).1, [["stop"]], "S11")

        let early = run(Core.State(), [.restored(registered: req([a])), .attached(adapter: .ready)])
        XCTAssertEqual(early.1, [["publish(Scanning)"], ["scan([A],dup=false)"]], "S11")

        let other = run(ready([.startRequested(req([a]))]), [.restored(registered: req([b]))])
        XCTAssertEqual(Core.request(other.0), req([a]), "S11")
    }

    // MARK: 닫기·질의

    func testS12_S13_closeAndPublishOwnership() {
        let busy = ready([.startRequested(req([a])), .internalJoined(services: [b])])
        let (state, out) = run(busy, [
            .close, .startRequested(req([a])), .restored(registered: req([a])), .discovered(adv([a])), .close,
        ])
        XCTAssertEqual(out, [["stop", "closeStreams"], ["reject(\(closed))"], [], [], []], "S12")
        XCTAssertTrue(Core.isClosed(state), "S12")

        var publishes = 0
        var current = ready([.startRequested(req([a]))])
        for event: Core.Event in [.internalJoined(services: [b]), .internalJoined(services: []), .internalLeft(0), .internalLeft(1), .adapterChanged(.ready)] {
            let (next, effects) = Core.step(current, event)
            current = next
            publishes += effects.filter { name($0).hasPrefix("publish") }.count
        }
        XCTAssertEqual(publishes, 0, "S13")
    }

    func testS14_S15_queriesAndInternalIDs() {
        let internalOnly = ready([.internalJoined(services: [a])])
        XCTAssertFalse(Core.isUserScanning(internalOnly), "S14")
        XCTAssertNil(Core.request(internalOnly), "S14")
        XCTAssertEqual(name(Core.phase(internalOnly)), "Idle", "S14")

        let scanning = run(internalOnly, [.startRequested(req([b]))]).0
        XCTAssertTrue(Core.isUserScanning(scanning), "S14")
        XCTAssertEqual(name(Core.phase(scanning)), "Scanning", "S14")

        var state = Core.State()
        XCTAssertEqual(Core.nextInternalID(state), 0, "S15")
        state = run(state, [.internalJoined(services: [a]), .internalJoined(services: [a]), .internalJoined(services: [a])]).0
        XCTAssertEqual(Core.nextInternalID(state), 3, "S15")
        state = run(state, [.internalLeft(1), .internalJoined(services: [a])]).0
        XCTAssertEqual(Core.nextInternalID(state), 4, "S15 뺀 id 는 다시 쓰지 않는다")
        XCTAssertEqual(run(state, [.discovered(adv([a]))]).1, [["deliver(0)", "deliver(2)", "deliver(3)"]], "S15 남은 id 만 id 순으로 전달")
    }

    // MARK: iOS 필터 한계 (guide/recipes/scan-connect.md 스캔 필터)

    func testPlatformScanKeepsServicesWithOtherFilterItems() {
        let filter = ScanFilter(
            serviceUUIDs: [a],
            manufacturerData: [ManufacturerDataFilter(companyID: 0x0059)],
            serviceData: [ServiceDataFilter(serviceUUID: b)]
        )
        let (scanning, out) = run(ready(), [.startRequested(ScanRequest(filter: filter))])
        XCTAssertEqual(out, [["scan([A],dup=false)", "publish(Scanning)"]], "다른 항목이 있어도 플랫폼 필터는 serviceUUIDs")

        let (widened, joined) = run(scanning, [.internalJoined(services: [])])
        XCTAssertEqual(joined, [["scan(nil,dup=false)"]], "서비스 조건 없는 내부 스캔이 겹치면 플랫폼 필터가 없어진다")
        let manufacturerOnly = AdvertisementData(manufacturerData: [0x0059: Data([0x01])])
        XCTAssertEqual(run(widened, [.discovered(manufacturerOnly)]).1, [["emit", "deliver(0)"]], "그때는 제조사 데이터만 맞는 광고도 사용자에게 간다")
    }
}
