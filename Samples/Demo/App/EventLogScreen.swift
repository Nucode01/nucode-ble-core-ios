import NucodeBleCore
import SwiftUI

/// `client.events` 를 받은 순서대로 보인다. 최신이 맨 아래
struct EventLogScreen: View {
    @Environment(BLEController.self) private var controller

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        ScrollViewReader { proxy in
            List(controller.events) { entry in
                Text("\(Self.timeFormat.string(from: entry.time)) \(entry.text)")
                    .font(.caption.monospaced())
                    .id(entry.id)
            }
            .overlay {
                if controller.events.isEmpty {
                    Text("아직 이벤트가 없습니다")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: controller.events.last?.id) { _, last in
                if let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onAppear {
                if let last = controller.events.last?.id { proxy.scrollTo(last, anchor: .bottom) }
            }
        }
        .navigationTitle("이벤트 로그")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("지우기") { controller.clearEvents() }
            }
        }
    }
}
