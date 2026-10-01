import Foundation
import NucodeBleCore
import os

// 가이드 스니펫(ios/guide/Snippets)에서 그대로 옮긴 것

/// Nordic UART Service(NUS) GATT 참조
enum NUS {
    static let service = ServiceRef(uuid: BLEUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
    /// 앱 → 기기 (write)
    static let rx = CharacteristicRef(service: service, uuid: BLEUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
    /// 기기 → 앱 (notify)
    static let tx = CharacteristicRef(service: service, uuid: BLEUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")!, instanceIndex: 0)
}

struct ReadyTimeout: Error {}

/// 세션이 `ready` 가 될 때까지 기다린다. 실패로 끝나면 그 `BLEError` 를, 시간이 지나면 `ReadyTimeout` 을 던진다
func waitUntilReady(_ session: any BLESession, timeout: Duration = .seconds(30)) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for await state in session.connectionStates {
                switch state {
                case .ready:
                    return
                case .disconnected(reason: .failed(let failure)):
                    throw BLEError(failure: failure)
                case .disconnected(reason: .requested), .disconnected(reason: .clientClosed):
                    throw CancellationError()
                default:
                    continue
                }
            }
            throw CancellationError()
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw ReadyTimeout()
        }
        defer { group.cancelAll() }
        try await group.next()
    }
}

/// 어댑터 상태를 화면 문구로 바꾼다. `start()` 전에는 `.unknown` 이다
func adapterMessage(_ state: AdapterState) -> String? {
    switch state {
    case .ready: return nil
    case .unknown, .resetting: return "블루투스 상태 확인 중"
    case .poweredOff: return "블루투스를 켜 주세요"
    case .unauthorized(canRequest: true): return "블루투스 권한을 허용해 주세요"
    case .unauthorized(canRequest: false): return "설정 > 개인정보 보호 > Bluetooth 에서 권한을 켜 주세요"
    case .unsupported: return "이 기기는 BLE 를 지원하지 않습니다"
    }
}

/// 명령이 던진 오류를 사용자 문구로 바꾼다. 분기는 `failure.code` 로 한다
func userMessage(for error: any Error) -> String {
    if error is CancellationError { return "취소됨" }
    guard let failure = (error as? BLEError)?.failure else { return "알 수 없는 오류" }
    switch failure.code {
    case .adapterUnavailable:
        return "블루투스를 켜 주세요"
    case .permissionDenied:
        return "블루투스 권한이 필요합니다"
    case .bleUnsupported:
        return "이 기기는 BLE 를 지원하지 않습니다"
    case .peripheralNotFound:
        return "기기를 찾지 못했습니다. 기기가 켜져 있고 가까이 있는지 확인해 주세요"
    case .notReady, .notConnected:
        return "기기가 아직 준비되지 않았습니다"
    case .operationTimeout:
        return "기기가 응답하지 않습니다"
    case .payloadTooLarge:
        return "보낼 데이터가 너무 큽니다"
    case .characteristicNotFound:
        return "이 기기가 지원하지 않는 기능입니다"
    default:
        return "BLE 오류 (\(failure.code.value))"
    }
}

private let boundaryLogger = Logger(subsystem: "kr.co.nucode.ble.Demo", category: "boundary")

/// 라이브러리 명령 호출 지점의 경계 로그. 대상 id 는 앞 8자만 남긴다
func boundaryLog(op: String, target: PeripheralID?, result: String, ms: Int) {
    let id = target.map { String($0.rawValue.prefix(8)) } ?? "-"
    boundaryLogger.info("op=\(op, privacy: .public) target=\(id, privacy: .public) result=\(result, privacy: .public) ms=\(ms)")
}

/// 경계 로그의 소요 시간(밀리초)
func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
}

/// 경계 로그의 결과 값: 라이브러리 실패면 코드, 아니면 오류 타입 이름
func failureCode(_ error: any Error) -> String {
    (error as? BLEError).map { $0.failure.code.value } ?? String(describing: type(of: error))
}
