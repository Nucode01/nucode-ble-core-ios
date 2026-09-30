import Foundation
import ManualTestDomain

/// 화면이 읽는 상태와 기록의 단일 소유자. 모든 사건은 `record` 로 들어와 기록·저장된다
@MainActor
public final class ConsoleState {
    public private(set) var adapter: AdapterStatus = .unknown
    public private(set) var scan: ScanStatus = .idle
    public private(set) var devices: [DiscoveredDevice] = []
    public private(set) var session = TestSession()
    public private(set) var log: EventLog
    /// 다음 실행에 쓸 앱 시작 등록(저장된 값)
    public private(set) var registration: DeviceRegistration?
    /// 이번 실행이 시작할 때 라이브러리에 넘긴 등록
    public private(set) var activeRegistration: DeviceRegistration?
    /// 마지막 저장 실패. 재부팅 뒤 첫 잠금 해제 전에는 파일을 못 쓸 수 있다
    public private(set) var storeError: String?
    /// 상태가 바뀔 때마다 부른다(표현 계층이 다시 그린다)
    public var onChange: (@MainActor () -> Void)?
    /// 기록 줄이 늘 때마다 부른다(점검표 자동 판정)
    public var onEntry: (@MainActor (LogEntry) -> Void)?
    /// 이 실행에서 기기별 마지막 연결 상태. 기록 줄에 직전 상태를 싣는다
    private var lastLinks: [DeviceId: LinkState] = [:]

    let logStore: any EventLogStore
    let clock: any Clock

    public init(logStore: any EventLogStore, clock: any Clock) {
        self.logStore = logStore
        self.clock = clock
        var restored: [LogEntry] = []
        var loadError: String?
        do { restored = try logStore.load() } catch { loadError = "기록 읽기 실패: \(error)" }
        log = EventLog(restoring: restored)
        storeError = loadError
    }

    /// 기록에 덧붙이고 파일에 쓴다
    func record(_ event: DomainEvent) {
        let entry = log.append(event, at: clock.now())
        do { try logStore.append(entry) } catch { storeError = "기록 쓰기 실패(seq \(entry.seq)): \(error)" }
        onChange?()
        onEntry?(entry)
    }

    /// 직전 상태를 돌려주고 새 상태로 바꾼다
    func swapLink(_ state: LinkState, of id: DeviceId) -> LinkState? {
        defer { lastLinks[id] = state }
        return lastLinks[id]
    }

    /// 명령을 부르는 순간의 상태
    func commandContext() -> CommandContext {
        CommandContext(device: session.deviceId, startedAt: clock.now(), adapter: adapter, link: session.link)
    }

    func set(adapter: AdapterStatus) { self.adapter = adapter }
    func set(scan: ScanStatus) { self.scan = scan }
    func set(registration: DeviceRegistration?) { self.registration = registration }
    func set(activeRegistration: DeviceRegistration?) { self.activeRegistration = activeRegistration }
    @discardableResult
    func mutateSession<T, E: Error>(_ body: (inout TestSession) throws(E) -> T) throws(E) -> T {
        try body(&session)
    }

    /// 새 기기면 true
    func upsert(_ device: DiscoveredDevice) -> Bool {
        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
            return false
        }
        devices.append(device)
        return true
    }

    public func recordAppPhase(_ phase: String) {
        record(.appPhaseChanged(phase))
    }

    public func clearDevices() {
        devices.removeAll()
        onChange?()
    }

    public func clearLog() {
        log.clear()
        do { try logStore.clear() } catch { storeError = "기록 비우기 실패: \(error)" }
        onChange?()
    }
}
