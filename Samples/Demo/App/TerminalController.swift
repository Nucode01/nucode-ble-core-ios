import Foundation
import NucodeBleCore
import Observation

/// 기기 하나의 NUS 터미널. 라이브러리 `BLESession` 호출을 그대로 보인다
@MainActor
@Observable
final class TerminalController {
    struct Line: Identifiable {
        let id: Int
        let time: Date
        let kind: Kind
        let text: String
    }

    enum Kind {
        case sent, received, system, error
    }

    let target: DeviceTarget
    private(set) var state: ConnectionState = .disconnected(reason: .initial)
    /// 오래된 줄부터 버린다. 최대 `maxLines`
    private(set) var lines: [Line] = []
    /// 연결 명령이 도는 동안 true
    private(set) var isBusy = false
    var autoReconnect = true
    var withoutResponse = false
    var appendNewline = true

    @ObservationIgnored private let session: any BLESession
    @ObservationIgnored private let connectTimeout: Duration
    @ObservationIgnored private let onConnected: @MainActor (DeviceTarget) -> Void
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastLabel: String?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private var notificationTask: Task<Void, Never>?

    static let maxLines = 500

    init(
        target: DeviceTarget,
        session: any BLESession,
        connectTimeout: Duration = .seconds(30),
        onConnected: @escaping @MainActor (DeviceTarget) -> Void = { _ in }
    ) {
        self.target = target
        self.session = session
        self.connectTimeout = connectTimeout
        self.onConnected = onConnected
    }

    /// 상태·알림 관찰을 연다. 첫 알림을 놓치지 않도록 connect 전에 부른다. 두 번 불러도 한 번만 한다
    func activate() {
        guard !activated else { return }
        activated = true
        let states = session.connectionStates
        stateTask = Task { [weak self] in
            for await state in states {
                self?.apply(state)
            }
        }
        let notifications = session.notifications(for: NUS.tx)
        notificationTask = Task { [weak self] in
            for await data in notifications {
                self?.append(.received, Self.display(data))
            }
        }
    }

    func connect() async {
        isBusy = true
        defer { isBusy = false }
        let clock = ContinuousClock()
        var begin = clock.now
        do {
            try await session.connect(options: ConnectOptions(autoReconnect: autoReconnect))
            boundaryLog(op: "connect", target: target.id, result: "ok", ms: milliseconds(clock.now - begin))
        } catch {
            boundaryLog(op: "connect", target: target.id, result: failureCode(error), ms: milliseconds(clock.now - begin))
            append(.error, userMessage(for: error))
            return
        }
        do {
            try await waitUntilReady(session, timeout: connectTimeout)
        } catch is ReadyTimeout {
            await disconnect()
            let seconds = connectTimeout.components.seconds
            append(.error, "기기를 찾지 못했습니다(\(seconds)초). 기기가 켜져 있는지 확인해 주세요")
            return
        } catch {
            append(.error, userMessage(for: error))
            return
        }
        begin = clock.now
        do {
            try await session.subscribe(NUS.tx)
            boundaryLog(op: "subscribe", target: target.id, result: "ok", ms: milliseconds(clock.now - begin))
        } catch {
            boundaryLog(op: "subscribe", target: target.id, result: failureCode(error), ms: milliseconds(clock.now - begin))
            append(.error, userMessage(for: error))
            return
        }
        onConnected(target)
    }

    func disconnect() async {
        let clock = ContinuousClock()
        let begin = clock.now
        await session.disconnect()
        boundaryLog(op: "disconnect", target: target.id, result: "ok", ms: milliseconds(clock.now - begin))
    }

    func send(_ text: String) async {
        guard !text.isEmpty else { return }
        let payload = Data((text + (appendNewline ? "\r\n" : "")).utf8)
        let mode: WriteMode = withoutResponse ? .withoutResponse : .withResponse
        let clock = ContinuousClock()
        let begin = clock.now
        do {
            _ = try await session.write(NUS.rx, value: payload, options: WriteOptions(mode: mode))
            boundaryLog(op: "write", target: target.id, result: "ok", ms: milliseconds(clock.now - begin))
            append(.sent, withoutResponse ? "\(text) (응답 없음)" : text)
        } catch {
            boundaryLog(op: "write", target: target.id, result: failureCode(error), ms: milliseconds(clock.now - begin))
            append(.error, userMessage(for: error))
        }
    }

    func clear() {
        lines = []
    }

    func append(_ kind: Kind, _ text: String) {
        lines.append(Line(id: nextID, time: Date(), kind: kind, text: text))
        nextID += 1
        if lines.count > Self.maxLines {
            lines.removeFirst(lines.count - Self.maxLines)
        }
    }

    func stateLabel(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected(reason: .initial), .disconnected(reason: .requested):
            return "연결 안 됨"
        case .disconnected(reason: .clientClosed):
            return "닫힘"
        case .disconnected(reason: .failed(let failure)):
            if failure.code == .adapterUnavailable {
                return autoReconnect ? "블루투스 꺼짐 — 켜지면 자동 재연결" : "블루투스 꺼짐"
            }
            return "끊김: \(failure.code.value)"
        case .connecting: return "연결 중"
        case .discoveringServices: return "서비스 찾는 중"
        case .configuring: return "설정 중"
        case .ready: return "준비됨"
        case .disconnecting: return "해제 중"
        case .recovering(let failure): return "다시 연결하는 중 (\(failure.code.value))"
        }
    }

    /// UTF-8 이면 끝의 줄바꿈을 떼고 문자열로, 아니면 "hex 0a 1b ..."
    static func display(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) {
            var scalars = text.unicodeScalars[...]
            while let last = scalars.last, last == "\r" || last == "\n" {
                scalars = scalars.dropLast()
            }
            return String(String.UnicodeScalarView(scalars))
        }
        return "hex " + data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private func apply(_ state: ConnectionState) {
        self.state = state
        let label = stateLabel(state)
        if label != lastLabel {
            lastLabel = label
            append(.system, label)
        }
    }
}
