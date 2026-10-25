import Foundation

enum DeskCommandError: LocalizedError, Equatable {
    case notConnected
    case staleFeedback
    case busy
    case invalidHeight
    case presetMissing
    case requiresForeground
    case unavailable
    case contextChanged
    case presetChanged

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "尚未连接升降桌，请先在 DeskLift 中连接。"
        case .staleFeedback:
            return "桌子高度反馈尚未更新，请稍候再试。"
        case .busy:
            return "桌子正在升降或等待停止完成，请稍候再试。"
        case .invalidHeight:
            return "高度无效或超出这张桌子支持的范围。"
        case .presetMissing:
            return "这个高度档位尚未保存，请先在 DeskLift 中保存。"
        case .requiresForeground:
            return "请先打开并激活 DeskLift，再执行升降操作。"
        case .unavailable:
            return "当前环境无法控制升降桌，请在这台 Mac 上使用 DeskLift。"
        case .contextChanged:
            return "连接的桌子或高度基准已改变，请重新发出指令。"
        case .presetChanged:
            return "保存的档位已改变，请重新确认目标高度。"
        }
    }
}

// A snapshot only: validating a command never connects to or moves a desk.
struct DeskCommandState: Sendable {
    var ready: Bool
    var rawHeight: Int?
    var baseHeight: Double?
    var speed: Double
    var canMove: Bool
    var feedbackAge: TimeInterval

    func currentHeight() throws -> Double {
        guard ready else { throw DeskCommandError.notConnected }
        guard feedbackAge.isFinite, (0...1.5).contains(feedbackAge) else {
            throw DeskCommandError.staleFeedback
        }
        guard let rawHeight, DPI.target(rawHeight) != nil,
              let baseHeight, baseHeight.isFinite, (0...250).contains(baseHeight) else {
            throw DeskCommandError.invalidHeight
        }
        return baseHeight + Double(rawHeight) / 100
    }

    func target(height: Double) throws -> Int {
        try validateMovement()
        guard let baseHeight, let raw = DPI.raw(cm: height, base: baseHeight),
              DPI.target(raw) != nil else {
            throw DeskCommandError.invalidHeight
        }
        return raw
    }

    // Presets contain the per-device raw position saved by DeskModel.
    func target(preset: Int?) throws -> Int {
        try validateMovement()
        guard let preset else { throw DeskCommandError.presetMissing }
        guard DPI.target(preset) != nil else { throw DeskCommandError.invalidHeight }
        return preset
    }

    private func validateMovement() throws {
        _ = try currentHeight()
        guard canMove, speed.isFinite, abs(speed) < 0.1 else {
            throw DeskCommandError.busy
        }
    }
}

// Retain the confirmed wire position; the displayed height is not converted
// back into a target after confirmation.
struct DeskCommandTarget: Sendable {
    let raw: Int
    let height: Double
    let sessionID: UUID
    let baseHeight: Double

    init(raw: Int, state: DeskCommandState, sessionID: UUID) throws {
        let validatedRaw = try state.target(preset: raw)
        guard let baseHeight = state.baseHeight else { throw DeskCommandError.invalidHeight }
        self.raw = validatedRaw
        self.height = baseHeight + Double(validatedRaw) / 100
        self.sessionID = sessionID
        self.baseHeight = baseHeight
    }

    func validatedRaw(in state: DeskCommandState, sessionID: UUID) throws -> Int {
        guard self.sessionID == sessionID, state.baseHeight == baseHeight else {
            throw DeskCommandError.contextChanged
        }
        return try state.target(preset: raw)
    }

    func validatePreset(_ raw: Int?) throws {
        guard raw == self.raw else { throw DeskCommandError.presetChanged }
    }
}
