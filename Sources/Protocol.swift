import Foundation

// DPI1C wire format adapted from KKQQ's MIT-licensed ha-linak-dpi1c-control,
// revision b61acfeeb9d716a631aee2ed3acebdfed6f50f15. See THIRD-PARTY-NOTICES.
enum DPI {
    static let suffix = "-338a-1024-8a49-009c0215f78a"
    static let control = "99fa0002" + suffix
    static let config = "99fa0011" + suffix
    static let status = "99fa0021" + suffix
    static let move = "99fa0031" + suffix
    static let service = "99fa0001" + suffix
    static let maxRaw = 6500 // Supported reference protocol travel; reject rather than guess.
    static let stop = Data([0xff, 0x00])
    static let heartbeat = Data([0x01, 0x80])
    static let readBase = Data([0x7f, 0x81, 0x00])
    static let readName = Data([0x7f, 0x26, 0x00])
    struct Status: Equatable {
        let raw: Int
        let speed: Double
    }
    static func status(_ data: Data) -> Status? {
        let b = Array(data)
        guard b.count >= 4 else { return nil }
        let raw = Int(b[0]) | Int(b[1]) << 8
        guard raw <= maxRaw else { return nil }
        let signed = Int16(bitPattern: UInt16(b[2]) | UInt16(b[3]) << 8)
        return Status(raw: raw, speed: Double(signed) / 100)
    }
    static func base(_ data: Data) -> Double? {
        let b = Array(data)
        guard b.count == 5, b[0] == 1, b[1] == 3, b[2] == 1 else { return nil }
        // This frame must be checked BEFORE generic empty-preset frames.
        let value = Double(Int(b[3]) | Int(b[4]) << 8) / 100
        return (0...250).contains(value) ? value : nil
    }
    static func target(_ raw: Int) -> Data? {
        guard (0...maxRaw).contains(raw) else { return nil }
        return Data([UInt8(raw & 255), UInt8(raw >> 8)])
    }
    static func raw(cm: Double, base: Double) -> Int? {
        guard cm.isFinite, base.isFinite else { return nil }
        let upper = base + Double(maxRaw) / 100
        guard upper.isFinite, cm >= base, cm <= upper else { return nil }
        let value = (cm - base) * 100
        // Check physical bounds before rounding. Decimal calibration values can
        // yield 6500.000000000002 at the exact valid upper height; rounding the
        // wire position then avoids rejecting it without accepting an outlier.
        let rounded = value.rounded()
        guard rounded >= 0, rounded <= Double(maxRaw) else { return nil }
        return Int(rounded)
    }
}

// A single movement owns a deadline. New feedback never extends that deadline.
struct MotionGuard {
    let target: Int
    let started: Double
    var lastProgress: Double
    var progressRaw: Int
    var hasMoved = false
    var stationarySince: Double?
    mutating func evaluate(raw: Int, speed: Double, feedbackAt: Double, now: Double) -> String? {
        if now - feedbackAt > 1.5 { return "高度反馈超时，已停止发送升降指令" }
        if now - started >= 45 { return "单次升降达到 45 秒，已停止" }
        if abs(raw - target) <= 15 { return "已到达目标高度" }
        let opposite = (target > raw && speed < -0.1) || (target < raw && speed > 0.1)
        if opposite { return "检测到反向运动，已交还桌面控制" }
        if abs(raw - progressRaw) >= 10 {
            progressRaw = raw
            lastProgress = now
        }
        if abs(speed) > 0.1 { hasMoved = true; stationarySince = nil }
        else if hasMoved {
            if stationarySince == nil { stationarySince = now }
            if now - stationarySince! > 0.35 { return "桌子已停下，升降指令已取消" }
        }
        if now - started > 2 && now - lastProgress > 3 { return "高度未继续变化，已停止" }
        return nil
    }
}
