import Foundation
import NucodeBleCore
import Observation

/// 앱 수명 동안 `BLEClient` 를 소유한다. 앱에서 `BLEClient(` 를 부르는 곳은 여기뿐이다
@MainActor
@Observable
final class BLEController {
    let client: BLEClient
    private(set) var adapter: AdapterState = .unknown

    @ObservationIgnored private var started = false
    @ObservationIgnored private var adapterTask: Task<Void, Never>?

    init() {
        client = BLEClient()
    }

    /// 어댑터 관찰을 연 뒤 client 를 시작한다. 두 번 불러도 한 번만 한다
    func start() {
        guard !started else { return }
        started = true
        let states = client.adapterStates
        adapterTask = Task { [weak self] in
            for await state in states {
                self?.adapter = state
            }
        }
        client.start()
    }
}
