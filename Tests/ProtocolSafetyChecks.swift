import Foundation

private struct ProtocolSafetyCheckFailure: Error, CustomStringConvertible {
    let number: Int
    let message: String

    var description: String { "Check \(number): \(message)" }
}

// Shared by the command-line runner and XCTest; does not initialize Bluetooth.
func runProtocolSafetyChecks() throws -> Int {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard value() else {
            throw ProtocolSafetyCheckFailure(number: checks, message: message)
        }
    }

    try check(DPI.status(Data([0x10, 0x27, 0, 0])) == nil, "reject unsupported travel")
    try check(DPI.status(Data([1, 2])) == nil, "reject short status")
    try check(DPI.status(Data([0xe8, 3, 0x9c, 0xff])) == DPI.Status(raw: 1000, speed: -1), "signed speed")
    try check(DPI.target(6500) == Data([0x64, 0x19]), "little endian target")
    try check(DPI.target(-1) == nil && DPI.target(6501) == nil, "reject unsafe targets")
    try check(DPI.raw(cm: .nan, base: 60) == nil, "reject nan")
    try check(DPI.raw(cm: 59.9, base: 60) == nil, "no silent clamping")
    try check(DPI.raw(cm: 110, base: 60) == 5000, "height conversion")
    try check(DPI.base(Data([1, 3, 1, 0x00, 0x19])) == 64, "calibration low byte zero must not parse as empty preset")
    try check(DPI.base(Data([1, 3, 1, 0x70, 0x17])) == 60, "base conversion")

    var g = MotionGuard(target: 5000, started: 0, lastProgress: 0, progressRaw: 1000)
    try check(g.evaluate(raw: 1000, speed: 0, feedbackAt: 0, now: 2)?.contains("反馈超时") == true, "stale feedback")
    try check(g.evaluate(raw: 1000, speed: 0, feedbackAt: 46, now: 46)?.contains("45 秒") == true, "fixed deadline")
    try check(g.evaluate(raw: 4990, speed: 0.2, feedbackAt: 1, now: 1)?.contains("到达") == true, "arrival")
    try check(g.evaluate(raw: 1000, speed: -1, feedbackAt: 1, now: 1)?.contains("反向") == true, "physical override")
    try check(g.evaluate(raw: 1000, speed: 0, feedbackAt: 4, now: 4)?.contains("未继续变化") == true, "stall")

    var h = MotionGuard(target: 5000, started: 0, lastProgress: 0, progressRaw: 1000)
    try check(h.evaluate(raw: 1050, speed: 1, feedbackAt: 0.1, now: 0.1) == nil, "normal movement")
    try check(h.evaluate(raw: 1100, speed: 0, feedbackAt: 0.2, now: 0.2) == nil, "short stationary transition")
    try check(h.evaluate(raw: 1100, speed: 0, feedbackAt: 0.6, now: 0.6)?.contains("停下") == true, "do not restart physical stop")

    return checks
}
