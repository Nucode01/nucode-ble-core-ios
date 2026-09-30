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
    /// 부팅 뒤 지난 초(`ProcessInfo.systemUptime`). 재부팅 직후인지 가른다(점검 7·9)
    public let systemUptime: TimeInterval?
    /// 실행 순간 앱이 알던 어댑터 상태. start() 전이라 보통 Unknown 이다
    public let adapter: AdapterStatus
    public init(
        reason: LaunchReason, appState: String, protectedDataAvailable: Bool,
        hasBluetoothCentralsKey: Bool, registration: DeviceRegistration?,
        systemUptime: TimeInterval? = nil, adapter: AdapterStatus = .unknown
    ) {
        self.reason = reason
        self.appState = appState
        self.protectedDataAvailable = protectedDataAvailable
        self.hasBluetoothCentralsKey = hasBluetoothCentralsKey
        self.registration = registration
        self.systemUptime = systemUptime
        self.adapter = adapter
    }
}

/// 명령을 부른 순간의 상태. 자동 판정이 "꺼진 상태에서 부른 명령"을 가른다
public struct CommandContext: Hashable, Codable, Sendable {
    public let device: DeviceId?
    public let startedAt: Date
    public let adapter: AdapterStatus
    /// 대상 기기의 연결 상태
    public let link: LinkState
    public init(device: DeviceId?, startedAt: Date, adapter: AdapterStatus, link: LinkState) {
        self.device = device
        self.startedAt = startedAt
        self.adapter = adapter
        self.link = link
    }
}

/// 시작 시점에 게이트웨이가 알려 준 세션 하나(복원·등록된 것)
public struct ObservedSession: Hashable, Codable, Sendable {
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

public struct GatewaySnapshot: Hashable, Codable, Sendable {
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
    case adapterChanged(AdapterStatus, previous: AdapterStatus? = nil)
    case scanChanged(ScanStatus)
    /// 이 실행에서 처음 본 기기만
    case deviceDiscovered(DiscoveredDevice)
    /// previous: 이 실행에서 그 기기의 직전 상태(모르면 nil)
    case linkChanged(DeviceId, LinkState, previous: LinkState? = nil)
    case servicesDiscovered(DeviceId, count: Int)
    case activeSubscriptionsChanged(DeviceId, Set<ProbeCharacteristic>)
    case notificationReceived(DeviceId, ProbeCharacteristic, Data, count: Int)
    case subscriptionRestoreFailed(DeviceId, characteristic: String, code: String)
    case diagnostic(code: String, message: String)
    case commandSucceeded(Command, detail: String, context: CommandContext? = nil)
    case commandFailed(Command, code: String, message: String, context: CommandContext? = nil)

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
            let uptime = r.systemUptime.map { " uptime=\(Int($0))s" } ?? ""
            return "실행: \(r.reason.label) appState=\(r.appState) protectedData=\(r.protectedDataAvailable) "
                + "bluetoothCentralsKey=\(r.hasBluetoothCentralsKey) 등록=\(reg)\(uptime)"
        case let .snapshotTaken(label, s):
            let sessions = s.sessions.map { "\($0.id.short) \($0.link.label) sub=\(Self.names($0.subscriptions))" }
            return "snapshot(\(label)): adapter=\(s.adapter.label) scanning=\(s.scanning) sessions=[\(sessions.joined(separator: ", "))]"
        case let .appPhaseChanged(phase): return "앱 \(phase)"
        case let .adapterChanged(a, _): return "adapter \(a.label)"
        case let .scanChanged(s): return "scan \(s.label)"
        case let .deviceDiscovered(d): return "발견 \(d.id.short) \(d.name ?? "-") rssi=\(d.rssi)"
        case let .linkChanged(id, state, _): return "\(id.short) \(state.label)"
        case let .servicesDiscovered(id, count): return "\(id.short) services \(count)개"
        case let .activeSubscriptionsChanged(id, set): return "\(id.short) activeSubscriptions \(Self.names(set))"
        case let .notificationReceived(id, c, value, count): return "\(id.short) \(c.rawValue) #\(count) \(value.hex)"
        case let .subscriptionRestoreFailed(id, c, code): return "\(id.short) 구독 복원 실패 \(c) \(code)"
        case let .diagnostic(code, message): return "진단 \(code) \(message)"
        case let .commandSucceeded(command, detail, _): return "\(command.rawValue) 성공 \(detail)"
        case let .commandFailed(command, code, message, _): return "\(command.rawValue) 실패 \(code) \(message)"
        }
    }

    /// 자동 판정이 읽는 구조화 사실. 발견·서비스·진단은 판정에 쓰지 않아 남기지 않는다
    public var fact: LogFact? {
        switch self {
        case let .launched(r):
            .launch(LaunchFact(reason: r.reason, systemUptime: r.systemUptime, adapter: r.adapter, registration: r.registration?.deviceId))
        case let .snapshotTaken(_, s): .snapshot(s)
        case let .appPhaseChanged(phase): .appPhase(phase)
        case let .adapterChanged(a, previous): .adapter(a, previous: previous)
        case let .scanChanged(s): .scan(s)
        case let .linkChanged(id, state, previous): .link(id, state, previous: previous)
        case let .activeSubscriptionsChanged(id, set): .activeSubscriptions(id, set)
        case let .notificationReceived(id, c, _, _): .notification(id, c)
        case let .commandSucceeded(command, _, context): .command(command, context, failure: nil)
        case let .commandFailed(command, code, _, context): .command(command, context, failure: code)
        case .deviceDiscovered, .servicesDiscovered, .subscriptionRestoreFailed, .diagnostic: nil
        }
    }

    static func names<S: Sequence>(_ set: S) -> String where S.Element == ProbeCharacteristic {
        "{" + set.map(\.rawValue).sorted().joined(separator: ",") + "}"
    }
}

public struct LaunchFact: Hashable, Codable, Sendable {
    public let reason: LaunchReason
    public let systemUptime: TimeInterval?
    public let adapter: AdapterStatus
    public let registration: DeviceId?
    public init(reason: LaunchReason, systemUptime: TimeInterval?, adapter: AdapterStatus, registration: DeviceId?) {
        self.reason = reason
        self.systemUptime = systemUptime
        self.adapter = adapter
        self.registration = registration
    }
}

/// 기록 줄의 구조화 사실. 화면 글(`text`)과 따로 둔다: 판정이 글을 해석하지 않게
public enum LogFact: Hashable, Codable, Sendable {
    case launch(LaunchFact)
    case snapshot(GatewaySnapshot)
    case appPhase(String)
    case adapter(AdapterStatus, previous: AdapterStatus?)
    case scan(ScanStatus)
    case link(DeviceId, LinkState, previous: LinkState?)
    case activeSubscriptions(DeviceId, Set<ProbeCharacteristic>)
    case notification(DeviceId, ProbeCharacteristic)
    /// failure: 실패 코드. nil 이면 성공
    case command(Command, CommandContext?, failure: String?)
}

public struct LogEntry: Hashable, Codable, Sendable, Identifiable {
    public let seq: Int
    /// 몇 번째 실행에서 쓴 줄인가(1부터). 백그라운드 재실행도 한 번으로 센다
    public let launch: Int
    public let at: Date
    public let kind: LogKind
    public let text: String
    /// 이전 형식 줄·모르는 사실은 nil(줄은 버리지 않는다)
    public let fact: LogFact?
    public var id: Int { seq }
    public init(seq: Int, launch: Int, at: Date, kind: LogKind, text: String, fact: LogFact? = nil) {
        self.seq = seq
        self.launch = launch
        self.at = at
        self.kind = kind
        self.text = text
        self.fact = fact
    }

    enum CodingKeys: String, CodingKey { case seq, launch, at, kind, text, fact }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        launch = try c.decode(Int.self, forKey: .launch)
        at = try c.decode(Date.self, forKey: .at)
        kind = try c.decode(LogKind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        fact = (try? c.decodeIfPresent(LogFact.self, forKey: .fact)) ?? nil
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
        let entry = LogEntry(seq: nextSeq, launch: launch, at: at, kind: event.kind, text: event.text, fact: event.fact)
        nextSeq += 1
        entries.append(entry)
        return entry
    }

    /// seq 는 이어서 센다(비운 뒤 줄과 섞이지 않게)
    public mutating func clear() {
        entries.removeAll()
    }
}
