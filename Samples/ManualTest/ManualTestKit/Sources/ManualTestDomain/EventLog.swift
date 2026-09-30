import Foundation

// MARK: 도메인 사건과 시간순 기록

public enum Command: String, Codable, Sendable {
    case startScan, stopScan, select, setAutoReconnect, connect, disconnect
    case read, write, subscribe, unsubscribe, saveRegistration, clearRegistration
}

public enum LaunchReason: String, Codable, Sendable {
    /// 앱이 포그라운드로 떴다(사용자 실행)
    case userLaunch
    /// 백그라운드로 떴다. 이 앱의 백그라운드 모드는 bluetooth-central 뿐이라 블루투스 복원 재실행으로 본다
    case bluetoothRelaunch

    /// launchOptions 의 bluetoothCentrals 키는 재실행에도 없었다(ios-design §13). 앱 상태로 판정한다
    public static func classify(launchedInBackground: Bool) -> LaunchReason {
        launchedInBackground ? .bluetoothRelaunch : .userLaunch
    }

    public var label: String {
        switch self {
        case .userLaunch: "사용자 실행"
        case .bluetoothRelaunch: "블루투스 복원 재실행(백그라운드)"
        }
    }
}

public struct LaunchRecord: Hashable, Sendable {
    public let reason: LaunchReason
    public let appState: String
    /// 재부팅 뒤 첫 잠금 해제 전이면 false. 이때는 기록 파일을 못 쓸 수 있다
    public let protectedDataAvailable: Bool
    public let hasBluetoothCentralsKey: Bool
    public let registration: DeviceRegistration?
    public init(
        reason: LaunchReason, appState: String, protectedDataAvailable: Bool,
        hasBluetoothCentralsKey: Bool, registration: DeviceRegistration?
    ) {
        self.reason = reason
        self.appState = appState
        self.protectedDataAvailable = protectedDataAvailable
        self.hasBluetoothCentralsKey = hasBluetoothCentralsKey
        self.registration = registration
    }
}

/// 시작 시점에 게이트웨이가 알려 준 세션 하나(복원·등록된 것)
public struct ObservedSession: Hashable, Sendable {
    public let id: DeviceId
    public let link: LinkState
    /// 구독 의도(CCCD 확인 상태가 아니다)
    public let subscriptions: Set<ProbeCharacteristic>
    public init(id: DeviceId, link: LinkState, subscriptions: Set<ProbeCharacteristic>) {
        self.id = id
        self.link = link
        self.subscriptions = subscriptions
    }
}

public struct GatewaySnapshot: Hashable, Sendable {
    public let adapter: AdapterStatus
    public let scanning: Bool
    public let sessions: [ObservedSession]
    public init(adapter: AdapterStatus, scanning: Bool, sessions: [ObservedSession]) {
        self.adapter = adapter
        self.scanning = scanning
        self.sessions = sessions
    }
}

public enum LogKind: String, Codable, CaseIterable, Sendable {
    case launch, adapter, scan, link, gatt, notification, command, diagnostic
}

public enum DomainEvent: Hashable, Sendable {
    case launched(LaunchRecord)
    case snapshotTaken(label: String, GatewaySnapshot)
    /// 포그라운드·백그라운드 전환. 재실행 뒤 사용자가 연 시점을 가른다
    case appPhaseChanged(String)
    case adapterChanged(AdapterStatus)
    case scanChanged(ScanStatus)
    /// 이 실행에서 처음 본 기기만
    case deviceDiscovered(DiscoveredDevice)
    case linkChanged(DeviceId, LinkState)
    case servicesDiscovered(DeviceId, count: Int)
    case activeSubscriptionsChanged(DeviceId, Set<ProbeCharacteristic>)
    case notificationReceived(DeviceId, ProbeCharacteristic, Data, count: Int)
    case subscriptionRestoreFailed(DeviceId, characteristic: String, code: String)
    case diagnostic(code: String, message: String)
    case commandSucceeded(Command, detail: String)
    case commandFailed(Command, code: String, message: String)

    public var kind: LogKind {
        switch self {
        case .launched, .snapshotTaken, .appPhaseChanged: .launch
        case .adapterChanged: .adapter
        case .scanChanged, .deviceDiscovered: .scan
        case .linkChanged: .link
        case .servicesDiscovered, .activeSubscriptionsChanged, .subscriptionRestoreFailed: .gatt
        case .notificationReceived: .notification
        case .commandSucceeded, .commandFailed: .command
        case .diagnostic: .diagnostic
        }
    }

    public var text: String {
        switch self {
        case let .launched(r):
            let reg = r.registration.map { "\($0.deviceId.short) auto=\($0.autoReconnect) sub=\(Self.names($0.subscribe))" } ?? "없음"
            return "실행: \(r.reason.label) appState=\(r.appState) protectedData=\(r.protectedDataAvailable) "
                + "bluetoothCentralsKey=\(r.hasBluetoothCentralsKey) 등록=\(reg)"
        case let .snapshotTaken(label, s):
            let sessions = s.sessions.map { "\($0.id.short) \($0.link.label) sub=\(Self.names($0.subscriptions))" }
            return "snapshot(\(label)): adapter=\(s.adapter.label) scanning=\(s.scanning) sessions=[\(sessions.joined(separator: ", "))]"
        case let .appPhaseChanged(phase): return "앱 \(phase)"
        case let .adapterChanged(a): return "adapter \(a.label)"
        case let .scanChanged(s): return "scan \(s.label)"
        case let .deviceDiscovered(d): return "발견 \(d.id.short) \(d.name ?? "-") rssi=\(d.rssi)"
        case let .linkChanged(id, state): return "\(id.short) \(state.label)"
        case let .servicesDiscovered(id, count): return "\(id.short) services \(count)개"
        case let .activeSubscriptionsChanged(id, set): return "\(id.short) activeSubscriptions \(Self.names(set))"
        case let .notificationReceived(id, c, value, count): return "\(id.short) \(c.rawValue) #\(count) \(value.hex)"
        case let .subscriptionRestoreFailed(id, c, code): return "\(id.short) 구독 복원 실패 \(c) \(code)"
        case let .diagnostic(code, message): return "진단 \(code) \(message)"
        case let .commandSucceeded(command, detail): return "\(command.rawValue) 성공 \(detail)"
        case let .commandFailed(command, code, message): return "\(command.rawValue) 실패 \(code) \(message)"
        }
    }

    static func names<S: Sequence>(_ set: S) -> String where S.Element == ProbeCharacteristic {
        "{" + set.map(\.rawValue).sorted().joined(separator: ",") + "}"
    }
}

public struct LogEntry: Hashable, Codable, Sendable, Identifiable {
    public let seq: Int
    /// 몇 번째 실행에서 쓴 줄인가(1부터). 백그라운드 재실행도 한 번으로 센다
    public let launch: Int
    public let at: Date
    public let kind: LogKind
    public let text: String
    public var id: Int { seq }
    public init(seq: Int, launch: Int, at: Date, kind: LogKind, text: String) {
        self.seq = seq
        self.launch = launch
        self.at = at
        self.kind = kind
        self.text = text
    }
}

/// 덧붙이기만 하는 시간순 기록. 비우기는 사용자가 명시할 때만
public struct EventLog: Sendable {
    public private(set) var entries: [LogEntry]
    /// 이번 실행 번호. 저장된 기록의 마지막 실행 + 1
    public let launch: Int
    private var nextSeq: Int

    public init(restoring entries: [LogEntry] = []) {
        self.entries = entries
        launch = (entries.map(\.launch).max() ?? 0) + 1
        nextSeq = (entries.map(\.seq).max() ?? 0) + 1
    }

    @discardableResult
    public mutating func append(_ event: DomainEvent, at: Date) -> LogEntry {
        let entry = LogEntry(seq: nextSeq, launch: launch, at: at, kind: event.kind, text: event.text)
        nextSeq += 1
        entries.append(entry)
        return entry
    }

    /// seq 는 이어서 센다(비운 뒤 줄과 섞이지 않게)
    public mutating func clear() {
        entries.removeAll()
    }
}
