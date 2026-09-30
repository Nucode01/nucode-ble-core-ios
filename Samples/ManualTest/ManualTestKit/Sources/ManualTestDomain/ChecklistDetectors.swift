import Foundation

// MARK: 점검 항목 자동 판정. 순수 함수: (시작 시각, 기록, 지금, 시작 때 문맥) → 판정.
// 기대는 contract/states.md §1–§6 을 옮긴 것이다. "시작" 이후(at ≥ armedAt) 줄만 본다.
// 어댑터·스캔·연결 사건은 라이브러리의 다른 스트림에서 와서 기록 순서가 몇 ms 뒤바뀔 수 있다. 그래서 순서를 엄격히 묻는 곳에 streamSkew 를 둔다.

public enum ChecklistDetectors {
    /// 다른 스트림 사이 기록 순서가 뒤바뀔 수 있는 폭
    public static let streamSkew: TimeInterval = 2

    public static func evaluate(_ id: Int, armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        let window = Array(entries.drop { $0.at < armedAt })
        switch id {
        case 1: return AdapterOffDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 2: return OffCommandsDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 3: return ReconnectDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 4: return NoReconnectDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 5: return LaunchOffDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 6: return AirplaneDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 7: return RebootConnectDetector.judge(armedAt: armedAt, entries: window, now: now, context: context)
        case 8: return RestorationDetector.judge(afterReboot: false, armedAt: armedAt, entries: window, now: now, context: context)
        case 9: return RestorationDetector.judge(afterReboot: true, armedAt: armedAt, entries: window, now: now, context: context)
        default: return ChecklistVerdict(.needsHuman("자동 판정 없는 항목"))
        }
    }

    static let adapterUnavailable = "ADAPTER_UNAVAILABLE"
    /// 어댑터 꺼짐으로 끝난 세션(states.md §2)
    static let offFinal = LinkState.disconnectedFailed(code: adapterUnavailable)
    static let linkFailed = LinkState.recovering(code: "LINK_FAILED")

    /// deadline 전이면 대기, 지나면 실패
    static func wait(_ waiting: String, until deadline: Date, now: Date, else failure: String, _ evidence: [Int]) -> ChecklistVerdict {
        now < deadline
            ? ChecklistVerdict(.pending(waiting, deadline: deadline), evidence: evidence)
            : ChecklistVerdict(.fail(failure), evidence: evidence)
    }

    /// 어댑터가 Ready 가 아닌 값에서 Ready 로 돌아온 첫 줄
    static func adapterReturn(_ entries: [LogEntry], from start: AdapterStatus) -> LogEntry? {
        var adapter = start
        for e in entries {
            guard case let .adapter(s, _)? = e.fact else { continue }
            if adapter != .ready, s == .ready { return e }
            adapter = s
        }
        return nil
    }
}

extension LogEntry {
    var linkFact: (DeviceId, LinkState)? {
        if case let .link(id, s, _)? = fact { return (id, s) }
        return nil
    }

    func link(of device: DeviceId) -> LinkState? {
        guard let (id, s) = linkFact, id == device else { return nil }
        return s
    }

    var launchFact: LaunchFact? {
        if case let .launch(f)? = fact { return f }
        return nil
    }

    var isForeground: Bool {
        if case .appPhase("active")? = fact { return true }
        return false
    }
}

// MARK: 1 Ready 에서 블루투스 끄기

/// 링크가 Ready 인 채 어댑터가 Ready 를 벗어나면 최종 `Disconnected(Failed:ADAPTER_UNAVAILABLE)`.
/// 그 사이 `Recovering(LINK_FAILED)` 하나만 허용(autoReconnect 켬일 때만, §3). 스캔 중이었으면 `Idle(Failed:SCAN_STOPPED_BY_ADAPTER)`
public enum AdapterOffDetector {
    /// 시작 → 설정 앱에서 끄기 → 최종 상태까지
    public static let timeout: TimeInterval = 120
    static let scanStopped = ScanStatus.failed(code: "SCAN_STOPPED_BY_ADAPTER")

    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        guard let device = context.deviceId else { return ChecklistVerdict(.needsHuman("대상 기기를 고르고 시작")) }
        let deadline = armedAt.addingTimeInterval(timeout)
        /// 마지막 Ready 뒤 허용된 상태만 지났다
        var readyChain = context.link == .ready
        var post: [LogEntry] = []
        /// Ready 에서 허용 밖 상태로 나간 줄(어댑터 줄보다 먼저 기록됐을 수 있다)
        var broke: LogEntry?
        var adapter = context.adapter
        var scanning = context.scanning
        var off: LogEntry?
        var scanningAtOff = false
        var scanStop: LogEntry?
        var final: LogEntry?

        func allowed(_ s: LinkState) -> Bool {
            let states = post.compactMap { $0.link(of: device) }
            if states.isEmpty { return s == ChecklistDetectors.offFinal || (context.autoReconnect && s == ChecklistDetectors.linkFailed) }
            return states == [ChecklistDetectors.linkFailed] && s == ChecklistDetectors.offFinal
        }

        for e in entries {
            switch e.fact {
            case let .adapter(s, _)?:
                defer { adapter = s }
                guard off == nil, adapter == .ready, s != .ready else { continue }
                off = e
                scanningAtOff = scanning
                if !readyChain {
                    if let broke, e.at.timeIntervalSince(broke.at) <= ChecklistDetectors.streamSkew {
                        return ChecklistVerdict(.fail("예상 밖 상태 \(broke.link(of: device)?.label ?? "?")"), evidence: post.map(\.seq) + [broke.seq, e.seq])
                    }
                    return ChecklistVerdict(.needsHuman("어댑터가 꺼질 때 Ready 가 아니었다"), evidence: [e.seq])
                }
            case let .scan(s)?:
                if scanning, s != .scanning {
                    if s == scanStopped {
                        scanStop = e
                    } else if off != nil {
                        return ChecklistVerdict(.fail("스캔이 \(s.label) 로 끝남"), evidence: [off!.seq, e.seq])
                    }
                }
                scanning = s == .scanning
            case let .link(id, s, _)? where id == device:
                guard final == nil else { continue }
                if off == nil {
                    if s == .ready {
                        readyChain = true
                        post = []
                        broke = nil
                        continue
                    }
                    guard readyChain else { continue }
                    if allowed(s) {
                        post.append(e)
                    } else {
                        readyChain = false
                        broke = e
                        post = []
                        continue
                    }
                } else {
                    guard allowed(s) else {
                        return ChecklistVerdict(.fail("예상 밖 상태 \(s.label)"), evidence: [off!.seq] + post.map(\.seq) + [e.seq])
                    }
                    post.append(e)
                }
                if s == ChecklistDetectors.offFinal { final = e }
            default:
                continue
            }
        }

        var evidence = post.map(\.seq)
        if let off { evidence.append(off.seq) }
        if let scanStop { evidence.append(scanStop.seq) }
        guard off != nil else {
            return ChecklistDetectors.wait("블루투스 끄기 대기", until: deadline, now: now, else: "어댑터 꺼짐 없음", evidence)
        }
        guard final != nil else {
            let last = post.last?.link(of: device)?.label ?? "Ready"
            return ChecklistDetectors.wait("최종 Disconnected(Failed:ADAPTER_UNAVAILABLE) 대기", until: deadline, now: now,
                                           else: "최종 Disconnected(Failed:ADAPTER_UNAVAILABLE) 없음(마지막 \(last))", evidence)
        }
        if scanningAtOff, scanStop == nil {
            return ChecklistDetectors.wait("스캔 종료 대기", until: deadline, now: now,
                                           else: "스캔이 Idle(Failed:SCAN_STOPPED_BY_ADAPTER) 로 끝나지 않음", evidence)
        }
        let via = post.count == 2 ? "Recovering(LINK_FAILED) 거쳐 " : ""
        let scan = scanStop != nil ? ", 스캔 Idle(Failed:SCAN_STOPPED_BY_ADAPTER)" : ""
        return ChecklistVerdict(.pass("\(via)Disconnected(Failed:ADAPTER_UNAVAILABLE)\(scan)"), evidence: evidence)
    }
}

// MARK: 2 꺼진 상태에서 read·connect

/// 어댑터가 Ready 가 아닐 때 부른 read·connect 가 하나 이상 있고 모두 거절된다. connect 는 `ADAPTER_UNAVAILABLE`(§4·§6),
/// read 는 세션이 끊긴 뒤라 `NOT_CONNECTED`(failure-codes.json) 또는 `ADAPTER_UNAVAILABLE`. 반환 전 실패는 연결 상태를 바꾸지 않는다(§4)
public enum OffCommandsDetector {
    /// 시작 → 명령까지
    public static let timeout: TimeInterval = 120
    /// 마지막 명령 뒤 연결 상태가 그대로인지 보는 시간(어댑터가 먼저 돌아오면 그때 끝낸다)
    public static let settle: TimeInterval = 3
    static let readCodes: Set<String> = ["NOT_CONNECTED", ChecklistDetectors.adapterUnavailable]

    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        var adapter = context.adapter
        var attempts: [LogEntry] = []
        var devices = Set<DeviceId>()
        var closed = false

        scan: for e in entries {
            switch e.fact {
            case let .adapter(s, _)?:
                adapter = s
                if s == .ready, !attempts.isEmpty { closed = true; break scan }
            case let .command(command, ctx, failure)? where command == .connect || command == .read:
                guard (ctx?.adapter ?? adapter) != .ready else { continue }
                attempts.append(e)
                if let device = ctx?.device { devices.insert(device) }
                let evidence = attempts.map(\.seq)
                guard let failure else {
                    return ChecklistVerdict(.fail("꺼진 상태에서 \(command.rawValue) 성공"), evidence: evidence)
                }
                if command == .connect, failure != ChecklistDetectors.adapterUnavailable {
                    return ChecklistVerdict(.fail("connect 가 \(failure)(기대 ADAPTER_UNAVAILABLE)"), evidence: evidence)
                }
                if command == .read, !readCodes.contains(failure) {
                    return ChecklistVerdict(.fail("read 가 \(failure)(기대 NOT_CONNECTED 또는 ADAPTER_UNAVAILABLE)"), evidence: evidence)
                }
            case let .link(id, s, _)? where devices.contains(id):
                return ChecklistVerdict(.fail("명령 뒤 연결 상태가 바뀜: \(s.label)"), evidence: attempts.map(\.seq) + [e.seq])
            default:
                continue
            }
        }

        let evidence = attempts.map(\.seq)
        guard let last = attempts.last else {
            return ChecklistDetectors.wait("꺼진 상태에서 읽기·연결 대기", until: armedAt.addingTimeInterval(timeout), now: now,
                                           else: "꺼진 상태 명령 없음", evidence)
        }
        let settledAt = last.at.addingTimeInterval(settle)
        if !closed, now < settledAt {
            return ChecklistVerdict(.pending("연결 상태가 그대로인지 확인", deadline: settledAt), evidence: evidence)
        }
        let codes = attempts.compactMap { e -> String? in
            guard case let .command(command, _, failure)? = e.fact else { return nil }
            return "\(command.rawValue) \(failure ?? "-")"
        }
        return ChecklistVerdict(.pass(codes.joined(separator: ", ") + ", 연결 상태 그대로"), evidence: evidence)
    }
}

// MARK: 3 블루투스 다시 켜기

/// autoReconnect 세션이 `Disconnected(Failed:ADAPTER_UNAVAILABLE)` 인 채 어댑터가 Ready 로 돌아오면 **한 번**
/// `Connecting → DiscoveringServices → Configuring → Ready`(Recovering 없음, §2), 그 뒤 activeSubscriptions ∋ probe.value, 알림 하나 이상
public enum ReconnectDetector {
    /// 시작 → 블루투스 켜기
    public static let adapterReturnTimeout: TimeInterval = 300
    /// 켠 뒤 Ready 까지
    public static let reconnectTimeout: TimeInterval = 30
    /// Ready 뒤 알림까지(펌웨어에서 보내는 시간 포함)
    public static let notificationTimeout: TimeInterval = 60
    static let path: [LinkState] = [.connecting, .discoveringServices, .configuring, .ready]

    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        guard let device = context.deviceId else { return ChecklistVerdict(.needsHuman("대상 기기를 고르고 시작")) }
        guard context.autoReconnect else { return ChecklistVerdict(.needsHuman("autoReconnect 를 켜고 시작")) }
        var adapter = context.adapter
        /// 대상이 Disconnected(Failed:ADAPTER_UNAVAILABLE) 에 닿았다. 재연결 경로는 그 뒤부터 센다
        var based = context.link == ChecklistDetectors.offFinal
        var base: LogEntry?
        var steps: [LogEntry] = []
        var returned: LogEntry?
        var basedAtReturn = false
        var ready: LogEntry?
        var subs: (LogEntry, Set<ProbeCharacteristic>)?
        var notification: LogEntry?
        var userConnect: LogEntry?

        func evidence() -> [Int] {
            [base, returned, subs?.0, notification, userConnect].compactMap { $0?.seq } + steps.map(\.seq)
        }

        for e in entries {
            if ready != nil, notification != nil, subs?.1.contains(.probeValue) == true { break }
            switch e.fact {
            case let .adapter(s, _)?:
                if returned == nil, adapter != .ready, s == .ready {
                    returned = e
                    basedAtReturn = based
                }
                adapter = s
            case let .link(id, s, _)? where id == device:
                if returned == nil, s == ChecklistDetectors.offFinal {
                    based = true
                    base = e
                    steps = []
                    subs = nil
                    continue
                }
                guard based else { continue }
                if ready != nil {
                    let reason = s == .connecting ? "Connecting 두 번" : "Ready 뒤 예상 밖 상태 \(s.label)"
                    return ChecklistVerdict(.fail(reason), evidence: evidence() + [e.seq])
                }
                steps.append(e)
                let index = steps.count - 1
                guard index < path.count, s == path[index] else {
                    let reason: String
                    if s == .connecting { reason = "Connecting 두 번" }
                    else if case .recovering = s { reason = "재연결 경로에 \(s.label)" }
                    else { reason = "예상 밖 상태 \(s.label)" }
                    return ChecklistVerdict(.fail(reason), evidence: evidence())
                }
                if s == .ready { ready = e }
            case let .activeSubscriptions(id, set)? where id == device && based:
                subs = (e, set)
            case let .notification(id, .probeValue)? where id == device && ready != nil && notification == nil:
                notification = e
            case .command(.connect, _, nil)? where based:
                userConnect = e
            default:
                continue
            }
        }

        guard let returned else {
            return ChecklistDetectors.wait("블루투스 켜기 대기", until: armedAt.addingTimeInterval(adapterReturnTimeout), now: now,
                                           else: "어댑터 Ready 복귀 없음", evidence())
        }
        if let first = steps.first, first.at < returned.at.addingTimeInterval(-ChecklistDetectors.streamSkew) {
            return ChecklistVerdict(.fail("어댑터가 꺼진 동안 \(first.link(of: device)?.label ?? "?")"), evidence: evidence())
        }
        guard basedAtReturn else {
            return ChecklistVerdict(.needsHuman("켤 때 대상이 Disconnected(Failed:ADAPTER_UNAVAILABLE) 가 아니었다"), evidence: evidence())
        }
        if userConnect != nil {
            return ChecklistVerdict(.needsHuman("재연결 창에서 연결을 눌렀다"), evidence: evidence())
        }
        guard let ready else {
            let seen = steps.compactMap { $0.link(of: device)?.label }.joined(separator: "→")
            return ChecklistDetectors.wait("재연결 대기 \(seen)", until: returned.at.addingTimeInterval(reconnectTimeout), now: now,
                                           else: "켠 뒤 \(Int(reconnectTimeout))초 안에 Ready 없음(\(seen.isEmpty ? "Connecting 없음" : seen))", evidence())
        }
        let deadline = ready.at.addingTimeInterval(notificationTimeout)
        guard notification != nil else {
            return ChecklistDetectors.wait("알림 대기(펌웨어에서 보낸다)", until: deadline, now: now, else: "Ready 뒤 알림 없음", evidence())
        }
        guard subs?.1.contains(.probeValue) == true else {
            return ChecklistDetectors.wait("activeSubscriptions 대기", until: deadline, now: now,
                                           else: "activeSubscriptions 에 probe.value 없음", evidence())
        }
        return ChecklistVerdict(.pass("재연결 1회 Connecting→DiscoveringServices→Configuring→Ready, activeSubscriptions {probe.value}, 알림 재개"),
                                evidence: evidence())
    }
}

// MARK: 4 autoReconnect 끄고 반복

/// autoReconnect=false 세션이 `Disconnected(Failed:ADAPTER_UNAVAILABLE)` 인 채 어댑터가 돌아와도 30초 동안 Connecting 이 없고 상태가 그대로다
public enum NoReconnectDetector {
    /// 시작 → 블루투스 켜기
    public static let adapterReturnTimeout: TimeInterval = 300
    /// 켠 뒤 재연결이 없는지 보는 시간
    public static let window: TimeInterval = 30

    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        guard let device = context.deviceId else { return ChecklistVerdict(.needsHuman("대상 기기를 고르고 시작")) }
        guard !context.autoReconnect else { return ChecklistVerdict(.needsHuman("autoReconnect 를 끄고 시작")) }
        var adapter = context.adapter
        var link = context.link
        var base: LogEntry?
        var returned: LogEntry?
        var linkAtReturn: LinkState?

        for e in entries {
            let evidence = [base, returned].compactMap { $0?.seq }
            switch e.fact {
            case let .adapter(s, _)?:
                if returned == nil, adapter != .ready, s == .ready {
                    returned = e
                    linkAtReturn = link
                }
                adapter = s
            case let .link(id, s, _)? where id == device:
                let afterBase = link == ChecklistDetectors.offFinal
                if s == .connecting, afterBase || returned != nil {
                    return ChecklistVerdict(.fail("autoReconnect 끔인데 Connecting"), evidence: evidence + [e.seq])
                }
                if let returned, e.at <= returned.at.addingTimeInterval(window) {
                    return ChecklistVerdict(.fail("켠 뒤 연결 상태가 바뀜: \(s.label)"), evidence: evidence + [e.seq])
                }
                link = s
                if s == ChecklistDetectors.offFinal { base = e }
            case .command(.connect, _, nil)? where link == ChecklistDetectors.offFinal:
                return ChecklistVerdict(.needsHuman("재연결 창에서 연결을 눌렀다"), evidence: evidence + [e.seq])
            default:
                continue
            }
        }

        let evidence = [base, returned].compactMap { $0?.seq }
        guard let returned else {
            return ChecklistDetectors.wait("블루투스 끄고 켜기 대기", until: armedAt.addingTimeInterval(adapterReturnTimeout), now: now,
                                           else: "어댑터 Ready 복귀 없음", evidence)
        }
        guard linkAtReturn == ChecklistDetectors.offFinal else {
            return ChecklistVerdict(.needsHuman("켤 때 대상이 Disconnected(Failed:ADAPTER_UNAVAILABLE) 가 아니었다(\(linkAtReturn?.label ?? "?"))"), evidence: evidence)
        }
        let end = returned.at.addingTimeInterval(window)
        if now < end {
            return ChecklistVerdict(.pending("\(Int(window))초 동안 재연결 없는지 확인", deadline: end), evidence: evidence)
        }
        return ChecklistVerdict(.pass("켠 뒤 \(Int(window))초 Connecting 없음, Disconnected(Failed:ADAPTER_UNAVAILABLE) 유지"), evidence: evidence)
    }
}

// MARK: 5 블루투스 끈 채 앱 시작

/// 시작 뒤 마지막 실행에서 (a) 실행 때 어댑터가 Ready 아님(Unknown 이면 첫 판정이 Ready 아님), (b) 꺼진 채 connect 는 `ADAPTER_UNAVAILABLE`,
/// (c) Unknown 중(→Ready 로 풀림) 또는 Ready 로 돌아온 뒤 2000ms 안에 부른 connect 는 성공하고 Ready 에 닿는다(§6)
public enum LaunchOffDetector {
    /// 시작 → 끄기 → 앱 종료·실행 → 두 번 연결
    public static let timeout: TimeInterval = 300
    /// "켠 직후"의 폭. Unknown 대기 상한(2000ms)과 같다
    public static let justOn: TimeInterval = 2
    /// 켠 직후 connect 에서 Ready 까지
    public static let connectToReady: TimeInterval = 30

    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        guard let launchIndex = entries.lastIndex(where: { $0.launchFact != nil }), let launch = entries[launchIndex].launchFact else {
            return ChecklistDetectors.wait("끈 채 앱 다시 실행 대기", until: armedAt.addingTimeInterval(timeout), now: now,
                                           else: "없음: 블루투스 끈 채 실행", [])
        }
        let launchEntry = entries[launchIndex]
        let run = entries[(launchIndex + 1)...].filter { $0.launch == launchEntry.launch }
        var evidence = [launchEntry.seq]

        // (a)
        let firstAdapter = run.first { if case .adapter? = $0.fact { true } else { false } }
        var launchedOff: Bool?
        if launch.adapter == .ready {
            launchedOff = false
        } else if launch.adapter != .unknown {
            launchedOff = true
        } else if case let .adapter(s, _)? = firstAdapter?.fact {
            launchedOff = s != .ready
            evidence.append(firstAdapter!.seq)
        }

        // (b)(c)
        var offConnect: LogEntry?
        var onConnect: LogEntry?
        var onReady: LogEntry?
        var adapter = launch.adapter
        var readyAt: Date?
        for (i, e) in run.enumerated() {
            switch e.fact {
            case let .adapter(s, _)?:
                if adapter != .ready, s == .ready { readyAt = e.at }
                adapter = s
            case let .command(.connect, ctx, failure)?:
                let startAdapter = ctx?.adapter ?? adapter
                let started = ctx?.startedAt ?? e.at
                let justOnCandidate: Bool
                switch startAdapter {
                case .ready:
                    guard let readyAt, started.timeIntervalSince(readyAt) <= justOn else { continue }
                    justOnCandidate = true
                case .unknown:
                    // Unknown 이 무엇으로 풀렸나(명령 뒤 첫 어댑터 줄)
                    let resolved = run[(i + 1)...].first { if case .adapter? = $0.fact { true } else { false } }
                    if case .adapter(.ready, _)? = resolved?.fact { justOnCandidate = true } else { justOnCandidate = false }
                case .poweredOff, .resetting:
                    justOnCandidate = false
                default:
                    continue
                }
                if justOnCandidate {
                    guard onConnect == nil else { continue }
                    onConnect = e
                    evidence.append(e.seq)
                    if let failure {
                        return ChecklistVerdict(.fail("켠 직후 connect 가 \(failure)"), evidence: evidence)
                    }
                    let device = ctx?.device
                    for later in run[(i + 1)...] {
                        guard let (id, s) = later.linkFact, device == nil || id == device else { continue }
                        if s == .ready { onReady = later; evidence.append(later.seq); break }
                        if s.isIdle {
                            return ChecklistVerdict(.fail("켠 직후 connect 뒤 \(s.label)"), evidence: evidence + [later.seq])
                        }
                    }
                } else {
                    guard offConnect == nil else { continue }
                    evidence.append(e.seq)
                    guard failure == ChecklistDetectors.adapterUnavailable else {
                        return ChecklistVerdict(.fail("꺼진 채 connect 가 \(failure ?? "성공")(기대 ADAPTER_UNAVAILABLE)"), evidence: evidence)
                    }
                    offConnect = e
                }
            default:
                continue
            }
        }

        var missing: [String] = []
        var seen: [String] = []
        if launchedOff == true { seen.append("끈 채 실행") } else { missing.append("끈 채 실행") }
        if offConnect != nil { seen.append("꺼진 채 connect ADAPTER_UNAVAILABLE") } else { missing.append("꺼진 채 connect 실패") }
        if onReady != nil { seen.append("켠 직후 connect → Ready") } else { missing.append(onConnect == nil ? "켠 뒤 2초 안 connect" : "켠 직후 connect 의 Ready") }
        if missing.isEmpty { return ChecklistVerdict(.pass(seen.joined(separator: ", ")), evidence: evidence) }
        var deadline = armedAt.addingTimeInterval(timeout)
        if let onConnect, onReady == nil { deadline = max(deadline, onConnect.at.addingTimeInterval(connectToReady)) }
        let status = (seen.isEmpty ? "" : "관찰: \(seen.joined(separator: ", ")) / ") + "대기: \(missing.joined(separator: ", "))"
        return ChecklistDetectors.wait(status, until: deadline, now: now, else: "없음: \(missing.joined(separator: ", "))", evidence)
    }
}

// MARK: 6 비행기 모드로 1–3

/// 1 과 3 을 같은 기록에 건다. 비행기 모드였는지는 기록으로 모르니 통과해도 사람 확인이다
public enum AirplaneDetector {
    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        let off = AdapterOffDetector.judge(armedAt: armedAt, entries: entries, now: now, context: context)
        guard case .pass = off.outcome else { return off }
        let on = ReconnectDetector.judge(armedAt: armedAt, entries: entries, now: now, context: context)
        guard case .pass = on.outcome else { return ChecklistVerdict(on.outcome, evidence: off.evidence + on.evidence) }
        return ChecklistVerdict(.needsHuman("자동 판정 통과(비행기 모드 여부는 사람 확인)"), evidence: off.evidence + on.evidence)
    }
}

// MARK: 7 재부팅 뒤 첫 연결

/// 시작 뒤 마지막 실행의 uptime < 10분이고, 그 실행의 첫 연결 시도가 실패 없이 Ready 에 닿는다
public enum RebootConnectDetector {
    /// 이보다 짧으면 재부팅 직후로 본다
    public static let recentBoot: TimeInterval = 600
    /// 시작 → 재부팅 → 실행 → 연결
    public static let timeout: TimeInterval = 900
    public static let connectToReady: TimeInterval = 30

    public static func judge(armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        let deadline = armedAt.addingTimeInterval(timeout)
        guard let launchIndex = entries.lastIndex(where: { $0.launchFact != nil }), let launch = entries[launchIndex].launchFact else {
            return ChecklistDetectors.wait("재부팅 뒤 앱 실행 대기", until: deadline, now: now, else: "재부팅 뒤 실행 없음", [])
        }
        let launchEntry = entries[launchIndex]
        guard let uptime = launch.systemUptime else {
            return ChecklistVerdict(.needsHuman("실행 기록에 uptime 없음"), evidence: [launchEntry.seq])
        }
        guard uptime < recentBoot else {
            return ChecklistVerdict(.needsHuman("재부팅 직후가 아님(uptime \(Int(uptime))s)"), evidence: [launchEntry.seq])
        }
        let run = entries[(launchIndex + 1)...].filter { $0.launch == launchEntry.launch }
        // 첫 연결 시도: connect 명령 또는 명령 없는 Connecting(등록 기기)
        guard let startIndex = run.firstIndex(where: {
            if case .command(.connect, _, _)? = $0.fact { return true }
            return $0.linkFact?.1 == .connecting
        }) else {
            return ChecklistDetectors.wait("첫 연결 대기", until: deadline, now: now, else: "재부팅 뒤 연결 시도 없음", [launchEntry.seq])
        }
        let start = run[startIndex]
        var evidence = [launchEntry.seq, start.seq]
        var device: DeviceId?
        if case let .command(_, ctx, failure)? = start.fact {
            if let failure { return ChecklistVerdict(.fail("첫 connect 가 \(failure)"), evidence: evidence) }
            device = ctx?.device
        } else {
            device = start.linkFact?.0
        }
        for e in run[(startIndex + 1)...] {
            guard let (id, s) = e.linkFact, device == nil || id == device else { continue }
            if s == .ready {
                return ChecklistVerdict(.pass("uptime \(Int(uptime))s, 첫 연결 Ready"), evidence: evidence + [e.seq])
            }
            if s.isIdle || { if case .recovering = s { true } else { false } }() {
                return ChecklistVerdict(.fail("첫 연결이 \(s.label)"), evidence: evidence + [e.seq])
            }
            evidence.append(e.seq)
        }
        return ChecklistDetectors.wait("첫 연결 Ready 대기", until: start.at.addingTimeInterval(connectToReady), now: now,
                                       else: "첫 연결이 \(Int(connectToReady))초 안에 Ready 에 닿지 않음", evidence)
    }
}

// MARK: 8·9 시스템 종료 뒤 복원 재실행

/// 시작 뒤 첫 실행이 블루투스 복원 재실행이고, 그 실행에서 앱을 열기(`앱 active`) 전에 등록 기기의 복원 세션(Ready)과 알림이 기록된다.
/// 9 는 그 실행의 uptime < 10분도 본다. 이전 실행이 정상 종료했는지는 기록에 없어 보지 않는다
public enum RestorationDetector {
    /// 시작 → 종료·재부팅 → 알림 → 재실행. 넘으면 다음에 앱을 열 때 실패로 판정한다
    public static let timeout: TimeInterval = 600
    public static let recentBoot: TimeInterval = RebootConnectDetector.recentBoot

    public static func judge(afterReboot: Bool, armedAt: Date, entries: [LogEntry], now: Date, context: ArmContext) -> ChecklistVerdict {
        let deadline = armedAt.addingTimeInterval(timeout)
        let noRelaunch = afterReboot ? "재부팅 뒤 복원 실행 없음" : "복원 재실행 없음"
        guard let launchIndex = entries.firstIndex(where: { $0.launchFact != nil }), let launch = entries[launchIndex].launchFact else {
            return ChecklistDetectors.wait("복원 재실행 대기(펌웨어 알림)", until: deadline, now: now, else: noRelaunch, [])
        }
        let launchEntry = entries[launchIndex]
        guard launch.reason == .bluetoothRelaunch else {
            return ChecklistVerdict(.fail(afterReboot ? noRelaunch : "복원 재실행 없이 사용자 실행"), evidence: [launchEntry.seq])
        }
        if afterReboot {
            guard let uptime = launch.systemUptime else {
                return ChecklistVerdict(.needsHuman("실행 기록에 uptime 없음"), evidence: [launchEntry.seq])
            }
            guard uptime < recentBoot else {
                return ChecklistVerdict(.needsHuman("재부팅 직후가 아님(uptime \(Int(uptime))s)"), evidence: [launchEntry.seq])
            }
        }
        guard let device = launch.registration else {
            return ChecklistVerdict(.needsHuman("등록 없이 재실행됨(현재 대상으로 저장 필요)"), evidence: [launchEntry.seq])
        }
        var evidence = [launchEntry.seq]
        var restored: LogEntry?
        var notification: LogEntry?
        var foreground: LogEntry?
        for e in entries[(launchIndex + 1)...] where e.launch == launchEntry.launch {
            if e.isForeground { foreground = e; break }
            switch e.fact {
            case let .snapshot(s)? where restored == nil && s.sessions.contains { $0.id == device && $0.link == .ready }:
                restored = e
            case let .link(id, .ready, _)? where restored == nil && id == device:
                restored = e
            case let .notification(id, _)? where notification == nil && id == device:
                notification = e
            default:
                continue
            }
        }
        evidence += [restored, notification, foreground].compactMap { $0?.seq }
        var missing: [String] = []
        if restored == nil { missing.append("복원 세션 Ready") }
        if notification == nil { missing.append("알림") }
        if missing.isEmpty {
            let uptime = afterReboot ? launch.systemUptime.map { " uptime \(Int($0))s," } ?? "" : ""
            return ChecklistVerdict(.pass("복원 재실행,\(uptime) 앱을 열기 전 세션 Ready·알림"), evidence: evidence)
        }
        let ended = foreground != nil || entries.contains { $0.launch > launchEntry.launch }
        if ended {
            return ChecklistVerdict(.fail("복원 재실행은 있었으나 앱을 열기 전 없음: \(missing.joined(separator: ", "))"), evidence: evidence)
        }
        return ChecklistDetectors.wait("복원 재실행 중 대기: \(missing.joined(separator: ", "))", until: deadline, now: now,
                                       else: "복원 재실행은 있었으나 없음: \(missing.joined(separator: ", "))", evidence)
    }
}
