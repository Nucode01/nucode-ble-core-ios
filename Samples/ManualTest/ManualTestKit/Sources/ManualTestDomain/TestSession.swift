import Foundation

public enum DomainError: Error, Hashable, Sendable {
    /// 시험 대상 기기를 고르지 않았다
    case noDeviceSelected
    /// 연결 중(Disconnected 가 아님)에는 기기·재연결 정책을 바꾸지 않는다
    case sessionActive(LinkState)
    case unknownChecklistItem(Int)

    public var code: String {
        switch self {
        case .noDeviceSelected: "NO_DEVICE_SELECTED"
        case .sessionActive: "SESSION_ACTIVE"
        case .unknownChecklistItem: "UNKNOWN_CHECKLIST_ITEM"
        }
    }
}

public struct NotificationStats: Hashable, Sendable {
    public private(set) var count = 0
    public private(set) var lastAt: Date?
    public private(set) var lastValue: Data?
    public init() {}

    mutating func record(_ value: Data, at: Date) {
        count += 1
        lastAt = at
        lastValue = value
    }
}

/// 시험 대상 기기 한 대의 집합체. 명령의 성패는 라이브러리가 판정한다.
/// GATT 명령을 여기서 막지 않는다: 막으면 라이브러리의 거절(ADAPTER_UNAVAILABLE·NOT_READY)을 시험할 수 없다.
public struct TestSession: Sendable {
    public private(set) var deviceId: DeviceId?
    public private(set) var autoReconnect = true
    public private(set) var link: LinkState = .disconnectedInitial
    /// 라이브러리 `activeSubscriptions`(이 연결에서 CCCD 확인된 것)
    public private(set) var activeSubscriptions: Set<ProbeCharacteristic> = []
    public private(set) var notifications = NotificationStats()
    /// 이 실행에서 Ready 에 닿은 횟수. 재연결 1회 판정용
    public private(set) var readyCount = 0

    public init() {}

    /// 연결 중이면 거절. 기기가 바뀌면 통계를 비운다
    public mutating func select(_ id: DeviceId) throws(DomainError) {
        guard link.isIdle else { throw .sessionActive(link) }
        guard id != deviceId else { return }
        deviceId = id
        link = .disconnectedInitial
        activeSubscriptions = []
        notifications = NotificationStats()
        readyCount = 0
    }

    public mutating func setAutoReconnect(_ on: Bool) throws(DomainError) {
        guard link.isIdle else { throw .sessionActive(link) }
        autoReconnect = on
    }

    /// 앱 시작 등록을 대상으로 받아들인다. 시작 때만 부른다
    public mutating func adopt(_ registration: DeviceRegistration) {
        deviceId = registration.deviceId
        autoReconnect = registration.autoReconnect
    }

    public func requireDevice() throws(DomainError) -> DeviceId {
        guard let deviceId else { throw .noDeviceSelected }
        return deviceId
    }

    /// 대상 기기의 사건만 반영한다. 반영했으면 true
    @discardableResult
    public mutating func apply(link state: LinkState, of id: DeviceId) -> Bool {
        guard id == deviceId else { return false }
        if state == .ready { readyCount += 1 }
        link = state
        return true
    }

    @discardableResult
    public mutating func apply(activeSubscriptions set: Set<ProbeCharacteristic>, of id: DeviceId) -> Bool {
        guard id == deviceId else { return false }
        activeSubscriptions = set
        return true
    }

    @discardableResult
    public mutating func recordNotification(_ value: Data, of id: DeviceId, at: Date) -> Bool {
        guard id == deviceId else { return false }
        notifications.record(value, at: at)
        return true
    }
}
