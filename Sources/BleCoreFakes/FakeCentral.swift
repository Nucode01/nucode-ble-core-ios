import Foundation
import NucodeBleCore

/// contract/README §sim 의 가짜 central. 기기는 하나(`peripheral`)다.
/// 어댑터는 `Ready`(poweredOn)·권한 허용으로 시작하고 `setAdapter`·`relaunchProcess` 로만 바뀐다.
/// CoreBluetooth 처럼 poweredOn 이 아닐 때 온 명령(스캔·스캔 멈춤·connect·cancel)은 무시하고 `misuses` 에 남긴다
/// (CB 는 `API MISUSE: can only accept this command while in the powered on state` 로그만 남긴다).
/// 콜백은 모두 core 큐에서 나간다.
@BLECoreActor
package final class FakeCentral: CentralPort {
    package private(set) var state: CentralPortState
    package private(set) var authorization: PortAuthorization
    package weak var delegate: (any CentralPortDelegate)?

    /// 가짜 기기. 기기 사건과 수신 기록은 여기서 다룬다.
    package let peripheral: FakePeripheral

    /// 마지막 `scanForPeripherals` 의 `allowDuplicates`(가짜 기기는 스캔 중 100ms 마다 결과를 낸다)
    package private(set) var scanAllowsDuplicates = false
    package var isScanning: Bool { scanning }
    /// poweredOn 이 아닐 때 와서 무시된 명령 이름(`connect`, `cancelPeripheralConnection` …), 온 순서대로
    package private(set) var misuses: [String] = []
    /// 받아들인 명령 이름(`scanForPeripherals`, `stopScan`, `connect`, `cancelPeripheralConnection`), 온 순서대로
    package private(set) var commands: [String] = []

    private let clock: any BLEClock
    private let timing: FakeTiming
    private let spec: FakeDeviceSpec
    private var scanning = false
    private var scanGeneration: UInt64 = 0
    private var scanServices: [BLEUUID]?
    /// 스캔 결과로 관측한 적이 있다. 그 뒤에야 `retrievePeripherals` 가 객체를 준다.
    private var observed = false

    package init(
        spec: FakeDeviceSpec,
        clock: any BLEClock = ScaledClock.realtime,
        timing: FakeTiming = FakeTiming(),
        state: CentralPortState = .poweredOn,
        authorization: PortAuthorization = .allowedAlways
    ) {
        self.spec = spec
        self.clock = clock
        self.timing = timing
        self.state = state
        self.authorization = authorization
        self.peripheral = FakePeripheral(spec: spec, clock: clock, timing: timing)
        peripheral.central = self
    }

    // MARK: CentralPort

    package func scanForPeripherals(services: [BLEUUID]?, allowDuplicates: Bool) {
        guard accepts("scanForPeripherals") else { return }
        scanning = true
        scanGeneration += 1
        scanServices = services
        scanAllowsDuplicates = allowDuplicates
        scheduleScanTick(generation: scanGeneration)
    }

    package func stopScan() {
        guard accepts("stopScan") else { return }
        haltScan()
    }

    package func retrievePeripherals(withIdentifiers identifiers: [PeripheralID]) -> [any PeripheralPort] {
        guard observed, identifiers.contains(peripheral.id) else { return [] }
        return [peripheral]
    }

    package func retrieveConnectedPeripherals(withServices services: [BLEUUID]) -> [any PeripheralPort] {
        guard peripheral.isLinked else { return [] }
        let offered = Set(spec.services.map(\.uuid))
        guard services.isEmpty || services.contains(where: offered.contains) else { return [] }
        return [peripheral]
    }

    package func connect(_ peripheral: any PeripheralPort) {
        guard accepts("connect"), peripheral === self.peripheral else { return }
        self.peripheral.connectRequested()
    }

    package func cancelPeripheralConnection(_ peripheral: any PeripheralPort) {
        guard accepts("cancelPeripheralConnection"), peripheral === self.peripheral else { return }
        self.peripheral.cancelRequested()
    }

    /// CoreBluetooth 처럼 poweredOn 일 때만 명령을 받는다. 아니면 무시하고 기록한다
    private func accepts(_ command: String) -> Bool {
        guard state == .poweredOn else {
            misuses.append(command)
            return false
        }
        commands.append(command)
        return true
    }

    private func haltScan() {
        scanning = false
        scanGeneration += 1
    }

    // MARK: 어댑터

    /// 실제 플랫폼이 앱에 알리는 경로와 같게 상태 콜백을 낸다. 켜짐이 아니게 되면 스캔이 멈추고
    /// (콜백 없음), 상태 콜백 뒤에 링크가 끊긴다(`didDisconnect`, 오류 있음).
    /// 대기 connect 는 상태 콜백 **전에** 실패한다(`didFailToConnect`, `CBInternalErrorDomain` 32). iPhone XR 실측(2026-09-30):
    /// 설정 앱으로 끄면 대기 connect 실패가 poweredOff 상태 콜백보다 60ms 먼저 왔다(contract/states.md §3).
    package func setAdapter(_ newState: CentralPortState, authorization newAuthorization: PortAuthorization = .allowedAlways) {
        state = newState
        authorization = newAuthorization
        if newState != .poweredOn { haltScan() }
        fakeEmit(self) { central in
            if central.state != .poweredOn {
                central.peripheral.failPendingConnect(error: PortError(domain: "CBInternalErrorDomain", code: 32, message: "Local device is powered off."))
            }
            central.delegate?.centralDidUpdateState(central)
            if central.state == .poweredOn {
                central.peripheral.attachIfPossible()
            } else {
                central.peripheral.dropLink(error: PortError(domain: "FakeCentral", code: 6, message: "adapter left poweredOn"))
            }
        }
    }

    /// 앱 프로세스가 새로 떠 manager 를 새로 만든 순간을 흉내 낸다(복원 재실행). 상태는 콜백 없이 `unknown` 이 되고
    /// OS 가 쥔 링크·대기 connect 는 그대로다. 실제처럼 `willRestoreState` 를 보낸 뒤 `setAdapter(.poweredOn)` 을 부른다.
    package func relaunchProcess() {
        state = .unknown
        haltScan()
    }

    // MARK: 콜백 (FakePeripheral 이 부른다. 이미 core 큐 위)

    func deliverDidConnect() {
        delegate?.central(self, didConnect: peripheral)
    }

    func deliverDidFailToConnect(error: PortError?) {
        delegate?.central(self, didFailToConnect: peripheral, error: error)
    }

    func deliverDidDisconnect(error: PortError?) {
        delegate?.central(self, didDisconnect: peripheral, error: error)
    }

    // MARK: 스캔 결과

    private func scheduleScanTick(generation: UInt64) {
        fakeAfter(self, clock: clock, milliseconds: timing.scanInterval) { central in
            guard central.scanning, central.scanGeneration == generation else { return }
            central.emitAdvertisement()
            central.scheduleScanTick(generation: generation)
        }
    }

    private func emitAdvertisement() {
        guard state == .poweredOn, peripheral.isAdvertising else { return }
        let advertised = Set(spec.services.filter(\.advertised).map(\.uuid))
        if let filter = scanServices, !filter.isEmpty, advertised.isDisjoint(with: filter) { return }
        observed = true
        let advertisement = AdvertisementData(localName: spec.advertisedName, serviceUUIDs: advertised, isConnectable: true)
        delegate?.central(self, didDiscover: peripheral, advertisement: advertisement, rssi: -50)
    }
}
