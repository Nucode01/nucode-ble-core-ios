import Foundation
import NucodeBleCore
import Observation

/// 화면 이동 값. 스캔 목록·최근 기기 행이 넘긴다
struct DeviceTarget: Hashable {
    let id: PeripheralID
    let name: String?
}

/// 스캔으로 발견한 기기 한 줄
struct DiscoveredDevice: Identifiable {
    var id: PeripheralID
    var name: String?
    var rssi: Int
    var advertisesNUS: Bool
}

/// 앱 수명 동안 `BLEClient` 를 소유한다. 앱에서 `BLEClient(` 를 부르는 곳은 여기뿐이다
@MainActor
@Observable
final class BLEController {
    let client: BLEClient
    private(set) var adapter: AdapterState = .unknown

    private(set) var isScanning = false
    private(set) var scanError: String?
    /// rssi 내림차순
    private(set) var devices: [DiscoveredDevice] = []
    var nusOnly = true
    private(set) var recent: DeviceTarget?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var adapterTask: Task<Void, Never>?
    @ObservationIgnored private var scanStateTask: Task<Void, Never>?
    @ObservationIgnored private var scanResultTask: Task<Void, Never>?
    @ObservationIgnored private var autoStopTask: Task<Void, Never>?
    @ObservationIgnored private var found: [PeripheralID: DiscoveredDevice] = [:]
    @ObservationIgnored private var terminals: [PeripheralID: TerminalController] = [:]

    private static let recentIDKey = "demo.recent.id"
    private static let recentNameKey = "demo.recent.name"
    private static let scanDuration: Duration = .seconds(15)

    init() {
        client = BLEClient()
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: Self.recentIDKey) {
            recent = DeviceTarget(id: PeripheralID(rawValue: raw), name: defaults.string(forKey: Self.recentNameKey))
        }
    }

    /// 어댑터·스캔 관찰을 연 뒤 client 를 시작한다. 두 번 불러도 한 번만 한다
    func start() {
        guard !started else { return }
        started = true
        let states = client.adapterStates
        adapterTask = Task { [weak self] in
            for await state in states {
                self?.adapter = state
            }
        }
        let scanStates = client.scanStates
        scanStateTask = Task { [weak self] in
            for await state in scanStates {
                self?.apply(state)
            }
        }
        let results = client.scanResults
        scanResultTask = Task { [weak self] in
            for await result in results {
                self?.upsert(result)
            }
        }
        client.start()
    }

    func startScan() async {
        autoStopTask?.cancel()
        scanError = nil
        found = [:]
        devices = []
        let filter = nusOnly ? ScanFilter(serviceUUIDs: [NUS.service.uuid]) : ScanFilter()
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            try await client.startScan(request: ScanRequest(filter: filter))
            boundaryLog(op: "startScan", target: nil, result: "ok", ms: Self.ms(clock.now - begin))
        } catch {
            boundaryLog(op: "startScan", target: nil, result: Self.code(error), ms: Self.ms(clock.now - begin))
            scanError = userMessage(for: error)
            return
        }
        autoStopTask = Task { [weak self] in
            try? await Task.sleep(for: Self.scanDuration)
            guard !Task.isCancelled else { return }
            await self?.stopScan()
        }
    }

    func stopScan() async {
        autoStopTask?.cancel()
        autoStopTask = nil
        let clock = ContinuousClock()
        let begin = clock.now
        await client.stopScan()
        boundaryLog(op: "stopScan", target: nil, result: "ok", ms: Self.ms(clock.now - begin))
    }

    /// 연결한 기기를 기억한다. 다음 실행에서 "최근 기기" 로 보인다
    func remember(_ target: DeviceTarget) {
        let defaults = UserDefaults.standard
        defaults.set(target.id.rawValue, forKey: Self.recentIDKey)
        defaults.set(target.name, forKey: Self.recentNameKey)
        recent = target
    }

    /// 기기별 터미널. 한 번 만든 것은 다시 쓴다(세션 관찰과 기록 유지). 세션을 열 수 없으면 nil
    func terminal(for target: DeviceTarget) -> TerminalController? {
        if let terminal = terminals[target.id] { return terminal }
        guard let session = try? client.session(for: target.id) else { return nil }
        let terminal = TerminalController(target: target, session: session) { [weak self] in
            self?.remember($0)
        }
        terminals[target.id] = terminal
        return terminal
    }

    private func apply(_ state: ScanState) {
        switch state {
        case .scanning:
            isScanning = true
        case .idle:
            isScanning = false
        case .failed(let failure):
            isScanning = false
            scanError = userMessage(for: BLEError(failure: failure))
        }
    }

    private func upsert(_ result: ScanResult) {
        let ad = result.advertisement
        var device = found[result.peripheralID]
            ?? DiscoveredDevice(id: result.peripheralID, name: nil, rssi: result.rssi, advertisesNUS: false)
        device.name = ad.localName ?? device.name
        device.rssi = result.rssi
        device.advertisesNUS = device.advertisesNUS || ad.serviceUUIDs.contains(NUS.service.uuid)
        found[result.peripheralID] = device
        devices = found.values.sorted { $0.rssi > $1.rssi }
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func code(_ error: any Error) -> String {
        (error as? BLEError).map { String(describing: $0.failure.code.value) } ?? String(describing: type(of: error))
    }
}
