import SwiftUI

@main
struct DemoApp: App {
    /// 앱당 하나. 프로세스가 끝날 때까지 둔다(close 하지 않는다)
    @State private var controller: BLEController

    init() {
        let controller = BLEController()
        controller.start()
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                Text("BLE 데모")
            }
            .environment(controller)
        }
    }
}
