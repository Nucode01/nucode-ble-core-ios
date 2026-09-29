import Foundation

/// 기기 객체 확보: `retrievePeripherals` → `retrieveConnectedPeripherals` → 확보 스캔(3000ms).
/// 앞의 둘은 동기로 끝난다. 스캔은 `BLEScanner` 를 거쳐 사용자 스캔과 합집합으로 돌고 공개 스캔 상태를 바꾸지 않는다.
/// 결과(`onResult`)는 정확히 한 번, 확보 스캔이 끝나면 그 스캔의 콜백(또는 기한)에서 나간다.
@BLECoreActor
package final class PeripheralResolver {
    private let id: PeripheralID
    private let central: any CentralPort
    private let scanner: BLEScanner
    private let clock: any BLEClock
    private var token: InternalScanToken?
    private var timer: Task<Void, Never>?
    private var onResult: (@BLECoreActor (Result<any PeripheralPort, BLEError>) -> Void)?

    package init(id: PeripheralID, central: any CentralPort, scanner: BLEScanner, clock: any BLEClock) {
        self.id = id
        self.central = central
        self.scanner = scanner
        self.clock = clock
    }

    /// `knownServices` 는 이전 연결에서 본 서비스 UUID 다(`retrieveConnectedPeripherals` 는 서비스를 요구한다)
    package func start(
        knownServices: [BLEUUID],
        onResult: @escaping @BLECoreActor (Result<any PeripheralPort, BLEError>) -> Void
    ) {
        self.onResult = onResult
        if let found = central.retrievePeripherals(withIdentifiers: [id]).first(where: { $0.id == id }) {
            finish(.success(found))
            return
        }
        if let found = central.retrieveConnectedPeripherals(withServices: knownServices).first(where: { $0.id == id }) {
            finish(.success(found))
            return
        }
        token = scanner.acquire(services: []) { [weak self] peripheral, _, _ in
            guard let self, peripheral.id == self.id else { return }
            self.finish(.success(peripheral))
        }
        timer = Task { @BLECoreActor [weak self, clock] in
            do { try await clock.sleep(milliseconds: Deadlines.peripheralScan) } catch { return }
            self?.finish(.failure(BLEError(failure: BLEFailure(
                code: .peripheralNotFound,
                message: "\(Deadlines.peripheralScan)ms 안에 기기를 찾지 못했다"
            ))))
        }
    }

    /// 결과 없이 정리한다. 멱등
    package func cancel() {
        onResult = nil
        cleanup()
    }

    private func finish(_ result: Result<any PeripheralPort, BLEError>) {
        guard let callback = onResult else { return }
        onResult = nil
        cleanup()
        callback(result)
    }

    private func cleanup() {
        timer?.cancel()
        timer = nil
        if let token {
            scanner.release(token)
            self.token = nil
        }
    }
}
