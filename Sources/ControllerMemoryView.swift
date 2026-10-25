import SwiftUI

struct ControllerMemoryView: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(model.controllerMemoryRows, id: \.slot) { row in
                        memoryRow(row)
                    }
                }
            }
            .formStyle(.grouped)

            if model.controllerMemoryBusy || model.controllerMemoryStatus != "未读取" {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    if model.controllerMemoryBusy {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.controllerMemoryStatus)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(12)
            }
        }
        .frame(width: 540, height: 440)
        .navigationTitle("设备内部记忆")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshControllerMemory()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(!model.canRefreshControllerMemory || model.controllerMemoryBusy)
                .help("重新读取控制器中的 4 个记忆档位")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("取消") {
                    model.cancelControllerMemoryOperation()
                }
                .disabled(!model.canCancelControllerMemory)
                .help("取消当前记忆操作")
            }
        }
    }

    private func memoryRow(_ row: ControllerMemoryRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.controllerMemoryName(row.slot))
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .help(model.controllerMemorySlotTitle(row.slot))
                if model.controllerMemoryHasCustomName(row.slot) {
                    Text("档位 \(row.slot + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    model.renameControllerMemory(row.slot)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("重命名\(model.controllerMemorySlotTitle(row.slot))")
                .help("重命名档位；留空恢复默认名称")
                .disabled(!model.canRenameControllerMemory)
                Spacer(minLength: 8)
                Text(row.heightText)
                    .monospacedDigit()
                Button(role: .destructive) {
                    model.requestControllerMemoryDelete(slot: row.slot)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除\(model.controllerMemorySlotTitle(row.slot))")
                .help("清空\(model.controllerMemorySlotTitle(row.slot))")
                .disabled(!model.canDeleteControllerMemory(row.slot))
            }

            HStack(spacing: 6) {
                TextField("高度", text: draftBinding(for: row.slot))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 76)
                    .accessibilityLabel("\(model.controllerMemorySlotTitle(row.slot))的写入高度，厘米")
                    .disabled(!model.canWriteControllerMemory || model.controllerMemoryBusy)
                Text("cm")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("保存当前高度") {
                    model.requestControllerMemoryWrite(slot: row.slot, heightText: nil)
                }
                .disabled(!model.canWriteControllerMemory || model.controllerMemoryBusy)
                .help("将桌子当前高度保存到\(model.controllerMemorySlotTitle(row.slot))")
                Button("写入") {
                    model.requestControllerMemoryWrite(
                        slot: row.slot,
                        heightText: draftBinding(for: row.slot).wrappedValue
                    )
                }
                .disabled(!model.canWriteControllerMemory || model.controllerMemoryBusy)
                .help("将输入的高度写入\(model.controllerMemorySlotTitle(row.slot))")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
    }

    private func draftBinding(for slot: Int) -> Binding<String> {
        Binding(
            get: {
                guard model.controllerMemoryDrafts.indices.contains(slot) else { return "" }
                return model.controllerMemoryDrafts[slot]
            },
            set: { value in
                guard model.controllerMemoryDrafts.indices.contains(slot) else { return }
                model.controllerMemoryDrafts[slot] = value
            }
        )
    }
}
