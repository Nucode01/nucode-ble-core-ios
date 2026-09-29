import Foundation

/// CoreBluetooth 가 준 `NSError` 를 포트의 `PortError` 로 옮긴다. Driver 가 도메인을 모르게 하려고 분리했다.
enum PortErrorConversion {
    static func portError(_ error: any Error) -> PortError {
        let ns = error as NSError
        return PortError(domain: ns.domain, code: ns.code, message: ns.localizedDescription)
    }
}
