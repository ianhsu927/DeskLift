import Foundation

struct RememberedDesk: Equatable {
    let id: UUID
    let name: String
}

final class DeskConnectionPreferences {
    private let defaults: UserDefaults
    private let enabledKey = "deskConnection.autoConnectEnabled"
    private let lastDeskKey = "deskConnection.lastDesk"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var autoConnectEnabled: Bool {
        get { defaults.object(forKey: enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: enabledKey) }
    }

    var lastDesk: RememberedDesk? {
        guard let saved = defaults.dictionary(forKey: lastDeskKey),
              let value = saved["id"] as? String, let id = UUID(uuidString: value),
              let name = saved["name"] as? String else { return nil }
        return RememberedDesk(id: id, name: name)
    }

    // Call only after the current device has completed validation and supplied
    // its calibrated height; discovery or a failed connection is not a choice.
    func remember(_ desk: RememberedDesk) {
        defaults.set(["id": desk.id.uuidString, "name": desk.name], forKey: lastDeskKey)
    }
}
