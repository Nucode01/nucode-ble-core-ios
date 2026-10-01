import Foundation
import NucodeBleCore

// region guide:failure-message
/// 명령이 던진 오류를 사용자 문구로 바꾼다. 분기는 `failure.code` 로 한다(message 는 사람용이라 바뀔 수 있다)
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
// endregion

// region guide:retryability
/// 같은 명령을 다시 불러도 되는가. 코드마다 기본값이 있고 원인에 따라 실패마다 다를 수 있다
func nextStep(for failure: BLEFailure) -> String {
    switch failure.retryability {
    case .never: return "고쳐야 한다(참조·크기·옵션이 틀렸다). 다시 불러도 같다"
    case .afterEnvironmentChange: return "블루투스·권한이 바뀌면 다시 한다(adapterStates 를 본다)"
    case .newConnectionMayHelp: return "끊고 다시 연결한 뒤 다시 한다"
    case .transientMayHelp: return "잠시 뒤 그대로 다시 한다"
    case .unknown: return "원인을 모른다. 한 번은 다시 해 볼 만하다"
    }
}
// endregion

func platformDetailExample(_ failure: BLEFailure) {
    // region guide:platform-detail
    // CoreBluetooth 원래 오류가 있으면 보존된다(로그·문의용). 분기에는 쓰지 않는다
    if let ios = failure.platformDetail?.ios {
        print("\(failure.code.value) ← \(ios.domain) \(ios.code) \(ios.symbolicName ?? "")")
    }
    // endregion
}

func eventsExample(_ client: any BLEClient) -> Task<Void, Never> {
    // region guide:events
    // 모든 기기의 연결 전이 · 탐색 결과 · 구독 복원 실패 · 진단이 한 줄로 온다(로그·분석용)
    Task {
        for await event in client.events {
            switch event {
            case .connection(let id, let state):
                print("[link] \(id.rawValue.prefix(8)) \(state)")
            case .services(let id, let services):
                print("[gatt] \(id.rawValue.prefix(8)) services=\(services.count)")
            case .subscriptionRestoreFailed(let id, let characteristic, let failure):
                // 재연결 뒤 구독을 되살리지 못했다. 세션은 Ready 로 가지만 이 알림은 오지 않는다
                print("[gatt] \(id.rawValue.prefix(8)) restore \(characteristic.uuid) failed \(failure.code.value)")
            case .diagnostic(let code, let message):
                print("[diag] \(code.value) \(message)")
            }
        }
    }
    // endregion
}

func snapshotExample(_ client: any BLEClient) async {
    // region guide:snapshot
    // 지금 상태를 한 번에 읽는다. 화면을 새로 열 때 스트림의 첫 값을 기다리지 않고 그릴 때 쓴다
    let snapshot = await client.snapshot()
    print("adapter:", snapshot.adapter, "scanning:", snapshot.scanning)
    for session in snapshot.sessions {
        // subscriptions 는 구독 의도(앱이 켜 둔 것)다. 지금 켜져 있는지는 activeSubscriptions 가 알려 준다
        print(session.peripheralID.rawValue, session.state, session.subscriptions.count)
    }
    // endregion
}
