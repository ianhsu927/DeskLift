import SwiftUI

struct MijiaLightView: View {
    @ObservedObject var model: MijiaLightModel
    @State private var brightnessDraft = 50.0
    @State private var temperatureDraft = 4000.0
    @State private var editingBrightness = false
    @State private var editingTemperature = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "lightbulb.fill")
                    .font(.title2)
                    .foregroundStyle(model.state?.isOn == true ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("米家显示器挂灯 2").font(.headline)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(model.canControl ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(model.status)
                        if !model.firmware.isEmpty {
                            Text("· 固件 \(model.firmware)")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.busy {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form {
                Section("灯光") {
                    Toggle("电源", isOn: Binding(
                        get: { model.state?.isOn ?? false },
                        set: { isOn in
                            guard model.canControl, !model.busy,
                                  isOn != model.state?.isOn else { return }
                            model.setPower(isOn)
                        }
                    ))
                    .toggleStyle(.switch)
                    .disabled(!model.canControl || model.busy)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("亮度")
                            Spacer()
                            Text(model.state == nil ? "—" : "\(Int(brightnessDraft.rounded()))%")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $brightnessDraft, in: 1...100, step: 1,
                               onEditingChanged: brightnessEditingChanged)
                            .accessibilityLabel("挂灯亮度")
                            .accessibilityValue("\(Int(brightnessDraft.rounded())) 百分比")
                            .disabled(!model.canControl || model.busy)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("色温")
                            Spacer()
                            Text(model.state == nil ? "—" : "\(Int(temperatureDraft.rounded())) K")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $temperatureDraft, in: 2700...6500, step: 1,
                               onEditingChanged: temperatureEditingChanged)
                            .accessibilityLabel("挂灯色温")
                            .accessibilityValue("\(Int(temperatureDraft.rounded())) 开尔文")
                            .disabled(!model.canControl || model.busy)
                        HStack {
                            Text("暖光")
                            Spacer()
                            Text("冷光")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section {
                    LabeledContent("IP 地址") {
                        TextField("192.168.1.100", text: $model.hostText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("挂灯 IP 地址")
                            .disabled(model.busy)
                    }
                    LabeledContent("设备 Token") {
                        SecureField(model.hasSavedCredentials ? "留空保留已保存 Token" : "32 位十六进制 Token",
                                    text: $model.tokenText)
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .accessibilityLabel("挂灯设备 Token")
                            .privacySensitive()
                            .disabled(model.busy)
                    }
                    HStack {
                        if model.hasSavedCredentials {
                            Button("忘记设备", role: .destructive) { model.forget() }
                                .disabled(model.busy)
                                .help("移除此 Mac 上保存的挂灯地址与 Token")
                        }
                        Spacer()
                        Button("保存并连接") { model.saveAndConnect() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.busy || model.hostText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                      || (!model.hasSavedCredentials && model.tokenText.isEmpty))
                    }
                } header: {
                    Text("局域网直连")
                } footer: {
                    Text("Token 保存在此 Mac 的钥匙串中。")
                }
            }
            .formStyle(.grouped)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                Text(model.detail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 22)
            .padding(.bottom, 16)
        }
        .frame(width: 460, height: 540)
        .navigationTitle("挂灯")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.refresh() } label: {
                    Label("刷新状态", systemImage: "arrow.clockwise")
                }
                .disabled(model.busy)
                .help("读取挂灯当前的开关、亮度与色温")
            }
        }
        .onAppear { synchronizeDrafts() }
        .onChange(of: model.state) { _, _ in synchronizeDrafts() }
        .onChange(of: model.busy) { _, busy in
            if !busy { synchronizeDrafts() }
        }
    }

    private func synchronizeDrafts() {
        guard let state = model.state else { return }
        if !editingBrightness { brightnessDraft = Double(state.brightness) }
        if !editingTemperature { temperatureDraft = Double(state.colorTemperature) }
    }

    private func brightnessEditingChanged(_ editing: Bool) {
        editingBrightness = editing
        guard !editing, model.canControl, !model.busy, let state = model.state else { return }
        let value = Int(brightnessDraft.rounded())
        if value != state.brightness { model.setBrightness(value) }
    }

    private func temperatureEditingChanged(_ editing: Bool) {
        editingTemperature = editing
        guard !editing, model.canControl, !model.busy, let state = model.state else { return }
        let value = Int(temperatureDraft.rounded())
        if value != state.colorTemperature { model.setColorTemperature(value) }
    }
}
