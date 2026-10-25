import Foundation
import XCTest

final class ControllerMemoryNameStoreTests: XCTestCase {
    func testNamesStayWithTheirDeviceAndSurviveStoreRecreation() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        let firstDevice = UUID()
        let secondDevice = UUID()
        let store = ControllerMemoryNameStore(defaults: defaults)
        XCTAssertEqual(store.names(for: firstDevice), ["", "", "", ""])

        XCTAssertTrue(store.setName("阅读", slot: 0, for: firstDevice))
        XCTAssertTrue(store.setName("站立办公", slot: 3, for: secondDevice))
        XCTAssertEqual(store.names(for: firstDevice), ["阅读", "", "", ""])
        XCTAssertEqual(store.names(for: secondDevice), ["", "", "", "站立办公"])

        let reopenedDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let recreated = ControllerMemoryNameStore(defaults: reopenedDefaults)
        XCTAssertEqual(recreated.names(for: firstDevice), ["阅读", "", "", ""])
        XCTAssertEqual(recreated.names(for: secondDevice), ["", "", "", "站立办公"])
    }

    func testNamesTrimEdgesAndReplaceEmbeddedLineBreaksAndControls() throws {
        let (defaults, _) = try isolatedDefaults()
        let device = UUID()
        let store = ControllerMemoryNameStore(defaults: defaults)
        store.setName(" \n 坐姿\r\n办公\t阅读\u{0000}完成\u{007f}备用 \n ", slot: 0, for: device)
        XCTAssertEqual(store.names(for: device)[0], "坐姿 办公 阅读 完成 备用")
    }

    func testBlankNamesFallBackAndEmojiLimitUsesWholeCharacters() throws {
        let (defaults, _) = try isolatedDefaults()
        let device = UUID()
        let store = ControllerMemoryNameStore(defaults: defaults)
        store.setName("原名称", slot: 1, for: device)
        store.setName(" \n\r\t\u{0000}\u{200d} ", slot: 1, for: device)
        XCTAssertEqual(store.names(for: device)[1], "")

        let emoji = "👩🏽‍💻"
        store.setName("  " + String(repeating: emoji, count: 25) + "\n", slot: 2, for: device)
        let stored = store.names(for: device)[2]
        XCTAssertEqual(stored.count, 24)
        XCTAssertEqual(stored, String(repeating: emoji, count: 24))
    }

    func testInvalidSlotsDoNotWriteAndNamesNeverChangeLocalHeightPresets() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        let device = UUID()
        let presetKey = "presets.\(device.uuidString)"
        defaults.set([1_000, 4_000], forKey: presetKey)
        let originalDomain = NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
        let store = ControllerMemoryNameStore(defaults: defaults)

        for slot in [-1, 4, Int.min, Int.max] {
            XCTAssertFalse(store.setName("无效", slot: slot, for: device))
        }
        let unchangedDomain = NSDictionary(dictionary: defaults.persistentDomain(forName: suiteName) ?? [:])
        XCTAssertTrue(unchangedDomain.isEqual(originalDomain))

        XCTAssertTrue(store.setName("午后阅读", slot: 2, for: device))
        XCTAssertEqual(defaults.array(forKey: presetKey) as? [Int], [1_000, 4_000])
        XCTAssertEqual(defaults.stringArray(forKey: "controllerMemoryNames.\(device.uuidString)"),
                       ["", "", "午后阅读", ""])
    }

    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "ControllerMemoryNameStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        return (defaults, suiteName)
    }
}
