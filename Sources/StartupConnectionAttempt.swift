import Foundation

// Chooses one remembered desk for this launch. The host owns discovery and
// connection; this value never sends Bluetooth or movement commands.
struct StartupConnectionAttempt {
    private(set) var target: RememberedDesk?
    private var hasBegun = false

    init() {}

    mutating func begin(enabled: Bool, rememberedDesk: RememberedDesk?,
                        preview: Bool, verificationOnly: Bool) -> Bool {
        guard !hasBegun else { return false }
        hasBegun = true
        guard enabled, !preview, !verificationOnly, let rememberedDesk else { return false }
        target = rememberedDesk
        return true
    }

    mutating func consume(id: UUID) -> Bool {
        guard target?.id == id else { return false }
        target = nil
        return true
    }

    mutating func cancel() {
        hasBegun = true
        target = nil
    }
}
