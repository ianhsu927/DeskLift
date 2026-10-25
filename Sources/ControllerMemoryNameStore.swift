import Foundation

struct ControllerMemoryNameStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func names(for deviceID: UUID) -> [String] {
        let saved = defaults.array(forKey: key(for: deviceID)) ?? []
        return (0..<4).map { slot in
            guard slot < saved.count, let name = saved[slot] as? String else { return "" }
            return Self.normalized(name)
        }
    }

    @discardableResult
    func setName(_ name: String, slot: Int, for deviceID: UUID) -> Bool {
        guard (0..<4).contains(slot) else { return false }
        var saved = names(for: deviceID)
        saved[slot] = Self.normalized(name)
        defaults.set(saved, forKey: key(for: deviceID))
        return true
    }

    private func key(for deviceID: UUID) -> String {
        "controllerMemoryNames.\(deviceID.uuidString)"
    }

    private static func normalized(_ name: String) -> String {
        let sanitized = String(name.map { character in
            let hasVisibleContent = character.unicodeScalars.contains {
                !CharacterSet.controlCharacters.contains($0) &&
                    !CharacterSet.whitespacesAndNewlines.contains($0)
            }
            let hasControl = character.unicodeScalars.contains { scalar in
                if CharacterSet.newlines.contains(scalar) { return true }
                guard CharacterSet.controlCharacters.contains(scalar) else { return false }
                // Preserve script joiners and emoji tags within a visible
                // grapheme, including family and profession emoji sequences.
                let isJoiningFormat = scalar.value == 0x200c || scalar.value == 0x200d ||
                    (0xe0020...0xe007f).contains(scalar.value)
                return !isJoiningFormat || !hasVisibleContent
            }
            return hasControl ? Character(" ") : character
        })
        let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(24)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
