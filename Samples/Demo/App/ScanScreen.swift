import NucodeBleCore
import SwiftUI

struct ScanScreen: View {
    @Environment(BLEController.self) private var controller

    var body: some View {
        @Bindable var controller = controller
        List {
            if let message = adapterMessage(controller.adapter) {
                Section {
                    Text(message).foregroundStyle(.orange)
                }
            }
            Section {
                Toggle("NUS 서비스만", isOn: $controller.nusOnly)
                    .disabled(controller.isScanning)
                Button {
                    Task {
                        if controller.isScanning {
                            await controller.stopScan()
                        } else {
                            await controller.startScan()
                        }
                    }
                } label: {
                    HStack {
                        Text(controller.isScanning ? "멈춤" : "스캔")
                        if controller.isScanning {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                if let error = controller.scanError {
                    Text(error).foregroundStyle(.red)
                }
            }
            if let recent = controller.recent {
                Section("최근 기기") {
                    NavigationLink(value: recent) {
                        DeviceRow(name: recent.name, id: recent.id, rssi: nil, advertisesNUS: false)
                    }
                }
            }
            Section("주변 기기") {
                if controller.devices.isEmpty {
                    Text(controller.isScanning ? "찾는 중…" : "발견한 기기가 없습니다. 스캔을 눌러 주세요")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.devices) { device in
                    NavigationLink(value: DeviceTarget(id: device.id, name: device.name)) {
                        DeviceRow(name: device.name, id: device.id, rssi: device.rssi, advertisesNUS: device.advertisesNUS)
                    }
                }
            }
        }
        .navigationTitle("BLE 데모")
        .navigationDestination(for: DeviceTarget.self) { target in
            if let terminal = controller.terminal(for: target) {
                TerminalScreen(controller: terminal)
            } else {
                Text("세션을 열 수 없습니다")
            }
        }
    }
}

private struct DeviceRow: View {
    let name: String?
    let id: PeripheralID
    let rssi: Int?
    let advertisesNUS: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name ?? "(이름 없음)")
                Text(String(id.rawValue.suffix(4)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if advertisesNUS {
                Text("NUS")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(.blue.opacity(0.2)))
            }
            if let rssi {
                Text("\(rssi) dBm")
                    .font(.caption)
                    .monospacedDigit()
            }
        }
    }
}
