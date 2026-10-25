import Foundation

// Presentation-only timing for a continuously observed height. Callers supply a
// monotonic clock; no state is persisted or used to issue movement commands.
struct HeightDurationTracker {
    private var referenceHeight: Double?
    private var stableSince: TimeInterval?
    private var lastObservedAt: TimeInterval?

    mutating func observe(height: Double?, isMoving: Bool, now: TimeInterval) {
        guard now.isFinite, now >= 0,
              let height, height.isFinite, height >= 0 else {
            reset()
            return
        }

        // A restarted or replaced clock starts a new observation interval.
        if let lastObservedAt, now < lastObservedAt { reset() }
        lastObservedAt = now

        guard !isMoving else {
            referenceHeight = nil
            stableSince = nil
            return
        }
        guard let referenceHeight, stableSince != nil else {
            self.referenceHeight = height
            stableSince = now
            return
        }

        // Compare against the interval's original height, not the previous
        // sample, so a sequence of small changes cannot hide a real drift.
        let roundingTolerance = min(1e-9, max(height.ulp, referenceHeight.ulp) * 4)
        if abs(height - referenceHeight) >= 0.2 - roundingTolerance {
            self.referenceHeight = height
            stableSince = now
        }
    }

    func elapsed(at now: TimeInterval) -> TimeInterval? {
        guard now.isFinite, now >= 0,
              let stableSince, let lastObservedAt,
              now >= lastObservedAt, now >= stableSince else { return nil }
        return now - stableSince
    }

    static func format(_ elapsed: TimeInterval) -> String {
        guard elapsed.isFinite, elapsed >= 0 else { return "—" }
        guard elapsed >= 60 else { return "\(Int(elapsed)) 秒" }
        guard elapsed >= 3_600 else { return "\(Int(elapsed / 60)) 分钟" }

        let hours = floor(elapsed / 3_600)
        // Bound the conversion even if a caller supplies an implausibly large
        // finite clock value. Normal durations retain minute-level precision.
        guard hours < 1_000_000 else { return "超过 999999 小时" }
        let minutes = Int(elapsed.truncatingRemainder(dividingBy: 3_600) / 60)
        return "\(Int(hours)) 小时 \(String(format: "%02d", minutes)) 分钟"
    }

    private mutating func reset() {
        referenceHeight = nil
        stableSince = nil
        lastObservedAt = nil
    }
}
