import Foundation
import XCTest

final class DeskConnectionPreferencesTests: XCTestCase {
    func testAutomaticConnectionDefaultsToEnabledAndPersistsUserChoice() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        let preferences = DeskConnectionPreferences(defaults: defaults)
        XCTAssertTrue(preferences.autoConnectEnabled)
        XCTAssertNil(preferences.lastDesk)

        preferences.autoConnectEnabled = false
        let reopened = DeskConnectionPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertFalse(reopened.autoConnectEnabled)
        reopened.autoConnectEnabled = true
        XCTAssertTrue(preferences.autoConnectEnabled)
    }

    func testConfirmedDeskSurvivesRecreationAndDisablingDoesNotForgetIt() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        let desk = RememberedDesk(id: UUID(), name: "我的升降桌")
        let preferences = DeskConnectionPreferences(defaults: defaults)
        preferences.remember(desk)
        preferences.autoConnectEnabled = false

        let reopened = DeskConnectionPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: suiteName)))
        XCTAssertEqual(reopened.lastDesk, desk)
        XCTAssertFalse(reopened.autoConnectEnabled)

        let replacement = RememberedDesk(id: UUID(), name: "另一张桌子")
        reopened.remember(replacement)
        XCTAssertEqual(preferences.lastDesk, replacement)
        XCTAssertFalse(preferences.autoConnectEnabled)
    }

    func testInvalidOrIncompleteRecordsNeverSelectADevice() throws {
        let (defaults, _) = try isolatedDefaults()
        let id = UUID().uuidString
        let invalidRecords: [Any] = [
            "a device name",
            ["name": "LINAK 桌子"],
            ["id": id],
            ["id": "", "name": "桌子"],
            ["id": "not-a-uuid", "name": "桌子"],
            ["id": String(id.dropLast()), "name": "桌子"],
            ["id": 123, "name": "桌子"] as [String: Any],
            ["id": id, "name": 123] as [String: Any],
            [id, "桌子"]
        ]
        let preferences = DeskConnectionPreferences(defaults: defaults)
        for record in invalidRecords {
            defaults.set(record, forKey: "deskConnection.lastDesk")
            XCTAssertNil(preferences.lastDesk)
        }
    }

    func testExistingPerDeviceDataIsNotTreatedAsAConnectionChoiceOrModified() throws {
        let (defaults, _) = try isolatedDefaults()
        let device = UUID()
        let presetKey = "presets.\(device.uuidString)"
        let namesKey = "controllerMemoryNames.\(device.uuidString)"
        let presets = [1_000, 4_000]
        let names = ["坐姿", "站姿", "阅读", ""]
        defaults.set(presets, forKey: presetKey)
        defaults.set(names, forKey: namesKey)

        let preferences = DeskConnectionPreferences(defaults: defaults)
        XCTAssertNil(preferences.lastDesk)
        preferences.remember(RememberedDesk(id: device, name: "我的桌子"))
        preferences.autoConnectEnabled = false
        XCTAssertEqual(defaults.array(forKey: presetKey) as? [Int], presets)
        XCTAssertEqual(defaults.stringArray(forKey: namesKey), names)
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "DeskConnectionPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return (defaults, suiteName)
    }
}
