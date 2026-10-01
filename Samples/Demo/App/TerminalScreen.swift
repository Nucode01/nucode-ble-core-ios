import NucodeBleCore
import SwiftUI

struct TerminalScreen: View {
    let controller: TerminalController
    @State private var draft = ""

    var body: some View {
        @Bindable var controller = controller
        VStack(spacing: 0) {
            header
            Divider()
            lineList
            Divider()
            quickCommands
            inputBar
        }
        .navigationTitle(controller.target.name ?? "기기")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("자동 재연결", isOn: $controller.autoReconnect)
                        .disabled(!isDisconnected)
                    Toggle("응답 없는 쓰기", isOn: $controller.withoutResponse)
                    Toggle("줄바꿈(\\r\\n) 붙이기", isOn: $controller.appendNewline)
                    Button("기록 지우기", role: .destructive) {
                        controller.clear()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { controller.activate() }
    }

    private var header: some View {
        HStack {
            Circle()
                .fill(stateColor)
                .frame(width: 10, height: 10)
            Text(controller.stateLabel(controller.state))
                .font(.subheadline)
            Spacer()
            Button {
                Task {
                    if isDisconnected {
                        await controller.connect()
                    } else {
                        await controller.disconnect()
                    }
                }
            } label: {
                if controller.isBusy {
                    ProgressView()
                } else {
                    Text(isDisconnected ? "연결" : "연결 끊기")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.isBusy && isDisconnected)
        }
        .padding()
    }

    private var lineList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.lines) { line in
                        Text("\(line.time.formatted(Self.timeFormat)) \(line.text)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(color(for: line.kind))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                }
                .padding(.horizontal)
            }
            .onChange(of: controller.lines.last?.id) { _, last in
                if let last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var quickCommands: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("시험 펌웨어 명령")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                ForEach(["IT:STATUS", "IT:DISCONNECT"], id: \.self) { command in
                    Button(command) {
                        Task { await controller.send(command) }
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private var inputBar: some View {
        HStack {
            TextField("보낼 내용", text: $draft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit(sendDraft)
            Button("보내기", action: sendDraft)
                .disabled(!isReady || draft.isEmpty)
        }
        .padding()
    }

    private func sendDraft() {
        guard isReady, !draft.isEmpty else { return }
        let text = draft
        draft = ""
        Task { await controller.send(text) }
    }

    private var isDisconnected: Bool {
        if case .disconnected = controller.state { return true }
        return false
    }

    private var isReady: Bool {
        if case .ready = controller.state { return true }
        return false
    }

    private var stateColor: Color {
        switch controller.state {
        case .ready: return .green
        case .disconnected(reason: .failed): return .red
        case .disconnected: return .gray
        default: return .orange
        }
    }

    private func color(for kind: TerminalController.Kind) -> Color {
        switch kind {
        case .sent: return .accentColor
        case .received: return .primary
        case .system: return .secondary
        case .error: return .red
        }
    }

    private static let timeFormat = Date.FormatStyle()
        .hour(.twoDigits(amPM: .omitted))
        .minute(.twoDigits)
        .second(.twoDigits)
}
