import Foundation

/// `sessions` 는 기기를 키로 한 유일한 딕셔너리다
@BLECoreActor
package final class SessionRegistry {
    package private(set) var sessions: [PeripheralID: Session] = [:]
    private let context: SessionContext

    package init(context: SessionContext) {
        self.context = context
    }

    package func session(for id: PeripheralID) -> Session {
        if let existing = sessions[id] { return existing }
        let created = Session(peripheralID: id, context: context)
        sessions[id] = created
        return created
    }

    package func snapshots() -> [SessionSnapshot] {
        sessions.values.map { $0.snapshot() }.sorted { $0.peripheralID.rawValue < $1.peripheralID.rawValue }
    }

    package func close() {
        for session in sessions.values { session.close() }
    }
}
