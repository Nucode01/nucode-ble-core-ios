import Foundation

/// 같은 프로세스에서 같은 `restoreIdentifier` 로 client 를 두 번 만들면 trap 한다(CANDIDATE-23).
/// CoreBluetooth 는 같은 식별자의 manager 둘을 받으면 복원 상태를 한쪽에만 주므로 조용히 어긋난다.
/// 식별자가 없는 client 는 여러 개 만들 수 있다. 식별자는 프로세스가 끝날 때까지 풀지 않는다.
enum RestoreIdentifierGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var claimed: Set<String> = []

    /// 처음 쓰면 true. 시험이 trap 없이 판정하려고 분리했다
    static func claim(_ identifier: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return claimed.insert(identifier).inserted
    }

    static func claimOrTrap(_ identifier: String?) {
        guard let identifier else { return }
        precondition(claim(identifier), "restoreIdentifier \(identifier) 로 이미 BLEClient 를 만들었다. 프로세스에서 하나만 만든다")
    }
}
