import Foundation
import ManualTestDomain

/// 게이트웨이 사건을 도메인 사건으로 바꿔 기록하고 집합체에 반영한다
@MainActor
public struct ObserveGateway {
    let gateway: any BleGateway
    let state: ConsoleState

    public init(gateway: any BleGateway, state: ConsoleState) {
        self.gateway = gateway
        self.state = state
    }

    /// 스트림이 끝날 때까지 돈다. 앱 수명 동안 한 번만 부른다
    public func run() async {
        for await event in gateway.events {
            handle(event)
        }
    }

    public func handle(_ event: GatewayEvent) {
        switch event {
        case let .adapter(status):
            state.set(adapter: status)
            state.record(.adapterChanged(status))
        case let .scan(status):
            state.set(scan: status)
            state.record(.scanChanged(status))
        case let .discovered(device):
            if state.upsert(device) {
                state.record(.deviceDiscovered(device))
            } else {
                state.onChange?()
            }
        case let .link(id, link):
            state.mutateSession { $0.apply(link: link, of: id) }
            state.record(.linkChanged(id, link))
        case let .services(id, count):
            state.record(.servicesDiscovered(id, count: count))
        case let .activeSubscriptions(id, set):
            state.mutateSession { $0.apply(activeSubscriptions: set, of: id) }
            state.record(.activeSubscriptionsChanged(id, set))
        case let .notification(id, characteristic, value):
            let now = state.clock.now()
            let counted = state.mutateSession { $0.recordNotification(value, of: id, at: now) }
            let count = counted ? state.session.notifications.count : 0
            state.record(.notificationReceived(id, characteristic, value, count: count))
        case let .subscriptionRestoreFailed(id, characteristic, code):
            state.record(.subscriptionRestoreFailed(id, characteristic: characteristic, code: code))
        case let .diagnostic(code, message):
            state.record(.diagnostic(code: code, message: message))
        }
    }
}
