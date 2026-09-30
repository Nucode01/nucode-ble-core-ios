import ManualTestApplication
import ManualTestInfrastructure
import SwiftUI
import UIKit

/// 조립 지점. 복원 재실행을 놓치지 않게 BLE 시작은 SwiftUI 화면이 아니라 didFinishLaunching 에서 한다(ios-design §8)
@main
struct ManualTestApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(console: delegate.container.console, checklist: delegate.container.checklist)
        }
        .onChange(of: scenePhase) { _, phase in
            delegate.container.state.recordAppPhase(String(describing: phase))
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    let container = AppContainer()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        container.launch(LaunchContext(
            launchedInBackground: application.applicationState == .background,
            appState: Self.label(application.applicationState),
            protectedDataAvailable: application.isProtectedDataAvailable,
            hasBluetoothCentralsKey: launchOptions?[.bluetoothCentrals] != nil
        ))
        return true
    }

    private static func label(_ state: UIApplication.State) -> String {
        switch state {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}

@MainActor
final class AppContainer {
    /// 고정 값. 바꾸면 이전 설치의 복원 상태를 이어받지 못한다
    static let restoreIdentifier = "kr.co.nucode.ble.ManualTest.central"

    let state: ConsoleState
    let console: ConsoleModel
    let checklist: ChecklistModel
    private let gateway: NucodeBleGateway
    private let registrationStore = FileRegistrationStore()
    private var launched = false

    init() {
        let clock = SystemClock()
        gateway = NucodeBleGateway(restoreIdentifier: Self.restoreIdentifier)
        state = ConsoleState(logStore: FileEventLogStore(), clock: clock)
        console = ConsoleModel(state: state, gateway: gateway, registrationStore: registrationStore)
        checklist = ChecklistModel(board: ChecklistBoard(store: FileChecklistStore(), clock: clock), state: state, clock: clock)
    }

    func launch(_ context: LaunchContext) {
        guard !launched else { return }
        launched = true
        let observe = ObserveGateway(gateway: gateway, state: state)
        Task { await observe.run() }
        RecordLaunch(gateway: gateway, state: state, registrationStore: registrationStore)(context)
    }
}
