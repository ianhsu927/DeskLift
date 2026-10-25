import AppIntents
import AppKit

enum DeskPreset: String, AppEnum {
    case sitting, standing
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "高度档位")
    static var caseDisplayRepresentations: [DeskPreset: DisplayRepresentation] = [
        .sitting: "坐姿", .standing: "站姿"
    ]
    var slot: Int { self == .sitting ? 0 : 1 }
    var name: String { self == .sitting ? "坐姿" : "站姿" }
}

private enum DeskIntentError: LocalizedError {
    case interrupted(String)
    var errorDescription: String? {
        switch self {
        case .interrupted(let reason): return "升降已中断：\(reason)"
        }
    }
}

@MainActor
private enum DeskIntentRuntime {
    static func app() throws -> AppDelegate {
        guard let app = NSApp.delegate as? AppDelegate else { throw DeskCommandError.unavailable }
        return app
    }

    static func prepareForMovement(_ app: AppDelegate) async throws {
        try Task.checkCancellation()
        guard app.window != nil else { throw DeskCommandError.unavailable }
        app.showWindow()
        // Foreground handoff may finish after perform starts. This wait belongs
        // only to this live invocation; nothing is retained for launch/reconnect.
        for _ in 0..<20 {
            try Task.checkCancellation()
            if NSApp.isActive, app.window.isVisible, app.window.isKeyWindow { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw DeskCommandError.requiresForeground
    }

    static func move(_ app: AppDelegate, to target: DeskCommandTarget, presetSlot: Int? = nil) async throws -> Double {
        try await prepareForMovement(app)
        let model = app.model
        try Task.checkCancellation()
        guard let id = try model.shortcutMove(to: target, presetSlot: presetSlot) else { return try model.shortcutHeight() }
        let deadline = ProcessInfo.processInfo.systemUptime + 46
        return try await withTaskCancellationHandler {
            // Wait for the existing MotionGuard to finish before returning a
            // Siri dialog, so speaking a result doesn't interrupt the motion.
            do {
                while model.motionID == id {
                    try Task.checkCancellation()
                    if ProcessInfo.processInfo.systemUptime >= deadline {
                        throw DeskIntentError.interrupted("等待升降结果超时")
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try Task.checkCancellation()
                guard model.connectionSessionID == target.sessionID, model.baseHeight == target.baseHeight else { throw DeskCommandError.contextChanged }
                guard let result = model.lastMotionResult, result.id == id, result.reachedTarget else {
                    throw DeskIntentError.interrupted(model.lastMotionResult?.reason ?? model.detail)
                }
                let actual = try model.shortcutHeight()
                guard !model.isActive, abs(actual - target.height) <= 0.151 else {
                    throw DeskIntentError.interrupted(model.detail)
                }
                return actual
            } catch {
                if model.motionID == id { model.stop("快捷指令已取消，升降已停止") }
                throw error
            }
        } onCancel: {
            Task { @MainActor in
                // A delayed cancellation must never stop a newer user action.
                if model.motionID == id { model.stop("快捷指令已取消，升降已停止") }
            }
        }
    }
}

struct ReadDeskHeightIntent: AppIntent {
    static var title: LocalizedStringResource = "查询升降桌高度"
    static var description = IntentDescription("读取当前已连接升降桌的实际高度，返回厘米数值。反馈过期或未连接时会报告错误。", categoryName: "升降桌")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        try Task.checkCancellation()
        let cm = try DeskIntentRuntime.app().model.shortcutHeight()
        let text = String(format: "%.1f", cm)
        return .result(value: cm, dialog: "升降桌当前高度是 \(text) 厘米。")
    }
}

struct StopDeskIntent: AppIntent {
    static var title: LocalizedStringResource = "停止升降桌"
    static var description = IntentDescription("立即请求停止当前桌子的升降，不需要高度或校准信息。", categoryName: "升降桌")
    static var authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let connected = try DeskIntentRuntime.app().model.shortcutStop()
        return .result(dialog: connected ? "已请求停止升降桌。" : "升降桌尚未连接，已取消应用中的升降指令。")
    }
}

struct MoveDeskToHeightIntent: AppIntent {
    static var title: LocalizedStringResource = "设置升降桌高度"
    static var description = IntentDescription("确认后移动到指定的厘米高度。需要桌子已连接；保持 DeskLift 控制面板在前台，切换应用会停止。", categoryName: "升降桌")
    static var openAppWhenRun: Bool { true }
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "目标高度（厘米）", requestValueDialog: "要将升降桌调整到多少厘米？")
    var height: Double
    static var parameterSummary: some ParameterSummary { Summary("将升降桌调至 \(\.$height) 厘米") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let app = try DeskIntentRuntime.app()
        let target = try app.model.shortcutTarget(height: height)
        let text = String(format: "%.1f", target.height)
        if #available(macOS 15.0, *) {
            try await requestConfirmation(dialog: "将升降桌调整到 \(text) 厘米？请确认桌面和周围没有障碍物。")
        } else {
            try await requestConfirmation()
        }
        let actual = try await DeskIntentRuntime.move(app, to: target)
        let actualText = String(format: "%.1f", actual)
        return .result(value: actual, dialog: "升降桌已在目标高度附近，当前 \(actualText) 厘米。")
    }
}

struct MoveDeskToPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "切换升降桌档位"
    static var description = IntentDescription("确认后使用这台 Mac 为当前桌子保存的坐姿或站姿高度。保持控制面板在前台，切换应用会停止。", categoryName: "升降桌")
    static var openAppWhenRun: Bool { true }
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground }
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    @Parameter(title: "档位", requestValueDialog: "切换到坐姿还是站姿？")
    var preset: DeskPreset
    static var parameterSummary: some ParameterSummary { Summary("将升降桌切换到 \(\.$preset)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        let app = try DeskIntentRuntime.app()
        let target = try app.model.shortcutPresetTarget(preset.slot)
        let text = String(format: "%.1f", target.height)
        if #available(macOS 15.0, *) {
            try await requestConfirmation(dialog: "将升降桌切换到\(preset.name)，高度 \(text) 厘米？请确认桌面和周围没有障碍物。")
        } else {
            try await requestConfirmation()
        }
        let actual = try await DeskIntentRuntime.move(app, to: target, presetSlot: preset.slot)
        let actualText = String(format: "%.1f", actual)
        return .result(value: actual, dialog: "已切换到\(preset.name)高度附近，当前 \(actualText) 厘米。")
    }
}

struct SaveDeskPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "保存升降桌档位"
    static var description = IntentDescription("将当前静止高度保存为这台 Mac 上的坐姿或站姿档位，仅保存到当前设备的本地设置。", categoryName: "升降桌")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    @available(macOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    @Parameter(title: "档位", requestValueDialog: "将当前高度保存为坐姿还是站姿？")
    var preset: DeskPreset
    static var parameterSummary: some ParameterSummary { Summary("将当前高度保存为 \(\.$preset)") }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        try Task.checkCancellation()
        let cm = try DeskIntentRuntime.app().model.shortcutSavePreset(preset.slot)
        let text = String(format: "%.1f", cm)
        return .result(value: cm, dialog: "已将 \(text) 厘米保存为这张桌子的\(preset.name)档位，仅保存在这台 Mac。")
    }
}
