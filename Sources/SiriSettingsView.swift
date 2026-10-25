import SwiftUI
import AppKit
import Security

struct SiriSettingsView: View {
    private let hasTeamSignature = Self.hasTeamSignature()
    var body: some View {
        Form {
            Section {
                Text("用 Siri 控制你的升降桌")
                    .font(.title2.bold())
                Text("先在“快捷指令”中添加 DeskLift 动作并命名，然后对 Siri 说出这个快捷指令的名称。")
                    .foregroundStyle(.secondary)
            }
            if !hasTeamSignature {
                Section("开发版本待签名") {
                    Text("当前版本使用本地临时签名。macOS 可以发现动作，但会拒绝执行；请使用 Apple Development 或 Developer ID 证书签名并重新安装。")
                        .foregroundStyle(.secondary)
                }
            }
            Section("设置方法") {
                Text("1. 打开“快捷指令”，新建快捷指令。")
                Text("2. 在动作搜索中输入 DeskLift，添加下面的动作。")
                Text("3. 命名为“桌子多高”“停止升降桌”“切换站姿”等。")
                Text("4. 唤起 Siri，说出保存的名称。")
                Button("打开快捷指令", action: Self.openShortcuts)
            }
            Section("可用动作") {
                LabeledContent("查询升降桌高度", value: "返回厘米数值")
                LabeledContent("停止升降桌", value: "立即请求停止")
                LabeledContent("设置升降桌高度", value: "输入目标厘米数")
                LabeledContent("切换升降桌档位", value: "坐姿 / 站姿")
                LabeledContent("保存升降桌档位", value: "保存到当前 Mac")
            }
            Section {
                Text("使用前请连接桌子并保持 DeskLift 运行。升降前会确认目标；控制面板需保持前台，切换应用、关闭面板或取消快捷指令会停止。")
                Text("坐姿和站姿使用当前设备的本地档位，请先保存。Mac 需要先创建并命名快捷指令，Siri 才能按名称运行。")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 610)
    }

    private static func openShortcuts() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") else { return }
        NSWorkspace.shared.open(url)
    }

    private static func hasTeamSignature() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String else { return false }
        return !team.isEmpty
    }
}
