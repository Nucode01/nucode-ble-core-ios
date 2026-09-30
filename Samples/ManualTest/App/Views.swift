import ManualTestApplication
import ManualTestDomain
import SwiftUI
import UIKit

struct RootView: View {
    let console: ConsoleModel
    let checklist: ChecklistModel

    var body: some View {
        TabView {
            NavigationStack { DeviceView(model: console) }
                .tabItem { Label("기기", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationStack { SessionView(model: console) }
                .tabItem { Label("세션", systemImage: "link") }
            NavigationStack { LogView(model: console) }
                .tabItem { Label("기록", systemImage: "list.bullet.rectangle") }
            NavigationStack { ChecklistView(model: checklist) }
                .tabItem { Label("점검표", systemImage: "checklist") }
        }
    }
}

// MARK: 기기

struct DeviceView: View {
    @Bindable var model: ConsoleModel

    var body: some View {
        List {
            Section("스캔") {
                Picker("조건", selection: $model.scanByService) {
                    Text("이름").tag(false)
                    Text("NUS 서비스").tag(true)
                }
                .pickerStyle(.segmented)
                if !model.scanByService {
                    TextField("이름 앞부분", text: $model.namePrefix)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                HStack {
                    Button("스캔 시작") { model.startScan() }
                        .accessibilityIdentifier("device.scanStart")
                    Spacer()
                    Button("중지") { model.stopScan() }
                        .accessibilityIdentifier("device.scanStop")
                }
                .buttonStyle(.borderless)
                StateRow(title: "스캔 상태", value: model.scan.label, id: "device.scan")
                StateRow(title: "어댑터", value: model.adapter.label, id: "device.adapter")
            }
            Section("발견한 기기 (\(model.devices.count))") {
                ForEach(model.devices, id: \.id) { device in
                    Button { model.select(device.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name ?? "(이름 없음)").font(.body)
                                Text(device.id.rawValue).font(.caption2.monospaced()).foregroundStyle(.secondary)
                                Text("RSSI \(device.rssi) · 서비스 \(device.serviceUUIDs.count)개").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if device.id == model.session.deviceId { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("device.row.\(device.name ?? "")")
                    .accessibilityValue(device.id == model.session.deviceId ? "selected" : "")
                }
            }
        }
        .navigationTitle("기기")
    }
}

// MARK: 세션

struct SessionView: View {
    @Bindable var model: ConsoleModel
    @State private var confirmKill = false

    var body: some View {
        Form {
            Section("상태") {
                StateRow(title: "어댑터", value: model.adapter.label, id: "session.adapter")
                StateRow(title: "스캔", value: model.scan.label, id: "session.scan")
                StateRow(title: "대상 기기", value: model.session.deviceId?.rawValue ?? "선택 안 함", id: "session.device")
                StateRow(title: "연결", value: model.session.link.label, id: "session.link")
                StateRow(title: "Ready 횟수(이번 실행)", value: "\(model.session.readyCount)", id: "session.readyCount")
                StateRow(title: "activeSubscriptions", value: names(model.session.activeSubscriptions), id: "session.subscriptions")
            }
            Section("마지막 알림") {
                StateRow(title: "받은 수", value: "\(model.session.notifications.count)", id: "session.notificationCount")
                StateRow(title: "시각", value: model.session.notifications.lastAt.map { LogTime.clock($0) } ?? "-")
                StateRow(title: "값", value: model.session.notifications.lastValue?.hex ?? "-")
            }
            Section {
                Toggle("autoReconnect", isOn: Binding(
                    get: { model.session.autoReconnect },
                    set: { model.setAutoReconnect($0) }
                ))
                .accessibilityIdentifier("session.autoReconnect")
                HStack {
                    Button("연결") { model.connect() }
                        .accessibilityIdentifier("session.connect")
                    Spacer()
                    Button("해제") { model.disconnect() }
                        .accessibilityIdentifier("session.disconnect")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("연결")
            } footer: {
                Text("connect 반환은 \"시도 시작\"이다. 결과는 연결 상태와 기록으로 본다. autoReconnect 는 연결 중에 못 바꾼다.")
            }
            Section("GATT") {
                HStack {
                    Button("probe.value 구독") { model.subscribe() }
                        .accessibilityIdentifier("session.subscribe")
                    Spacer()
                    Button("구독 해제") { model.unsubscribe() }
                }
                .buttonStyle(.borderless)
                Button("probe.value 읽기") { model.read() }
                    .accessibilityIdentifier("session.read")
                HStack {
                    TextField("NUS rx 로 보낼 문자열", text: $model.nusText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("쓰기") { model.writeNus() }.buttonStyle(.borderless)
                }
            }
            Section {
                StateRow(title: "이번 실행", value: describe(model.activeRegistration), id: "session.activeRegistration")
                StateRow(title: "저장됨(다음 실행)", value: describe(model.registration), id: "session.savedRegistration")
                HStack {
                    Button("현재 대상으로 저장") { model.saveRegistration() }
                        .accessibilityIdentifier("session.saveRegistration")
                    Spacer()
                    Button("등록 해제", role: .destructive) { model.clearRegistration() }
                        .accessibilityIdentifier("session.clearRegistration")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("앱 시작 등록")
            } footer: {
                Text("등록은 start() 전에만 되므로 다음 실행부터 적용된다. 점검 8·9 는 등록이 있어야 복원 재실행이 세션을 이어받는다. 점검 5 는 등록을 해제하고 한다.")
            }
            Section {
                Button("앱 종료(SIGKILL)", role: .destructive) { confirmKill = true }
            } footer: {
                Text("점검 8·9 용. 시스템 종료처럼 프로세스를 죽인다. 앱 전환기에서 쓸어 닫으면 iOS 가 다시 실행하지 않는다.")
            }
            Section("최근 명령") {
                if model.recentCommands.isEmpty { Text("없음").foregroundStyle(.secondary) }
                ForEach(model.recentCommands) { entry in
                    Text("\(LogTime.clock(entry.at)) \(entry.text)").font(.caption.monospaced())
                }
            }
            if let error = model.storeError {
                Section("저장 오류") { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }
        .navigationTitle("세션")
        .confirmationDialog("앱 프로세스를 SIGKILL 로 끝냅니다", isPresented: $confirmKill) {
            Button("종료", role: .destructive) { model.killSelf() }
        }
    }

    private func names(_ set: Set<ProbeCharacteristic>) -> String {
        "{" + set.map(\.rawValue).sorted().joined(separator: ",") + "}"
    }

    private func describe(_ registration: DeviceRegistration?) -> String {
        guard let registration else { return "없음" }
        return "\(registration.deviceId.short) auto=\(registration.autoReconnect)"
    }
}

// MARK: 기록

struct LogView: View {
    let model: ConsoleModel
    @State private var kind: LogKind?
    @State private var confirmClear = false

    private var rows: [LogEntry] {
        let all = model.entries.reversed()
        guard let kind else { return Array(all) }
        return all.filter { $0.kind == kind }
    }

    var body: some View {
        List(rows) { entry in
            VStack(alignment: .leading, spacing: 2) {
                Text("L\(entry.launch) \(LogTime.clock(entry.at)) [\(entry.kind.rawValue)]")
                    .font(.caption2.monospaced())
                    .foregroundStyle(entry.launch == model.launch ? Color.secondary : Color.orange)
                Text(entry.text).font(.caption.monospaced())
            }
        }
        .listStyle(.plain)
        .navigationTitle("기록 (이번 실행 L\(model.launch))")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Picker("종류", selection: $kind) {
                        Text("전체").tag(LogKind?.none)
                        ForEach(LogKind.allCases, id: \.self) { Text($0.rawValue).tag(Optional($0)) }
                    }
                } label: {
                    Label(kind?.rawValue ?? "전체", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("비우기", role: .destructive) { confirmClear = true }
            }
        }
        .confirmationDialog("기록을 모두 지웁니다", isPresented: $confirmClear) {
            Button("비우기", role: .destructive) { model.clearLog() }
        }
    }
}

// MARK: 점검표

struct ChecklistView: View {
    let model: ChecklistModel
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        List {
            ForEach(Checklist.items) { item in
                ChecklistRow(model: model, item: item)
            }
            if let error = model.storeError {
                Text(error).foregroundStyle(.red).font(.caption)
            }
        }
        .navigationTitle("점검표")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("초기화", role: .destructive) { confirmReset = true }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(copied ? "복사됨" : "복사") {
                    UIPasteboard.general.string = model.report()
                    copied = true
                }
                .accessibilityIdentifier("checklist.copy")
                ShareLink(item: model.report()) { Image(systemName: "square.and.arrow.up") }
                    .accessibilityIdentifier("checklist.export")
            }
        }
        .confirmationDialog("점검 결과를 모두 지웁니다", isPresented: $confirmReset) {
            Button("초기화", role: .destructive) { model.resetAll() }
        }
        .onAppear { copied = false }
    }
}

/// 항목 하나: 시작 · 상태 · 할 일 · 자동 판정 내용 · 근거(펼침) · 수동 판정
struct ChecklistRow: View {
    let model: ChecklistModel
    let item: ChecklistItem
    @State private var showEvidence = false

    var body: some View {
        let result = model.checklist.result(for: item.id)
        Section {
            HStack {
                Text(model.status(result))
                    .font(.callout.bold())
                    .foregroundStyle(color(result))
                    .accessibilityIdentifier("checklist.status.\(item.id)")
                    .accessibilityValue(result.verdict.rawValue)
                Spacer()
                Button(result.auto == nil ? "시작" : "다시 시작") { model.arm(item.id) }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("checklist.arm.\(item.id)")
            }
            Text(item.instruction).font(.caption)
            if let auto = result.auto {
                Text(auto.outcome.detail).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("checklist.detail.\(item.id)")
                if !auto.evidence.isEmpty {
                    DisclosureGroup("근거 \(auto.evidence.count)줄", isExpanded: $showEvidence) {
                        ForEach(Array(auto.evidence.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.caption2.monospaced())
                        }
                    }
                    .font(.caption)
                }
            }
            if !result.note.isEmpty { Text("메모: \(result.note)").font(.caption).foregroundStyle(.secondary) }
            NavigationLink("수동 판정·메모") { ChecklistItemView(model: model, item: item) }
                .font(.caption)
        } header: {
            Text("\(item.id). \(item.title)")
        }
    }

    private func color(_ result: ChecklistResult) -> Color {
        switch result.verdict {
        case .pending: result.isJudging ? .blue : .secondary
        case .pass: .green
        case .fail: .red
        case .skip, .needsHuman: .orange
        }
    }
}

struct ChecklistItemView: View {
    let model: ChecklistModel
    let item: ChecklistItem
    @State private var verdict: Verdict = .pending
    @State private var note = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let result = model.checklist.result(for: item.id)
        Form {
            Section("기대 결과") { Text(item.expectation) }
            if let auto = result.auto {
                Section("자동 판정") {
                    Text("\(auto.outcome.label): \(auto.outcome.detail)")
                    Text("시작 \(LogTime.full(auto.armedAt))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("판정", selection: $verdict) {
                    ForEach(Verdict.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("판정")
            } footer: {
                Text("저장하면 수동 판정이 되고 자동 판정은 멈춘다(근거는 남는다). 다시 자동으로 하려면 \"다시 시작\".")
            }
            Section("메모") {
                TextEditor(text: $note).frame(minHeight: 120)
            }
            if let at = result.updatedAt {
                Section { Text("마지막 저장 \(LogTime.full(at)) · \(result.source.label)").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("\(item.id). \(item.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("저장") {
                model.mark(item.id, verdict: verdict, note: note)
                dismiss()
            }
        }
        .onAppear {
            let result = model.checklist.result(for: item.id)
            verdict = result.verdict
            note = result.note
        }
    }
}

struct StateRow: View {
    let title: String
    let value: String
    /// UI 자동화(ManualTestUITests)가 값을 읽는 식별자
    var id: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
            Spacer()
            Text(value).font(.callout.monospaced()).multilineTextAlignment(.trailing).foregroundStyle(.secondary)
                .accessibilityIdentifier(id ?? "")
        }
    }
}
