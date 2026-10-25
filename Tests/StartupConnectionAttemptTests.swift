import Foundation
import XCTest

final class StartupConnectionAttemptTests: XCTestCase {
    func testInitialStateHasNoTargetAndConsumingNothingDoesNotBeginAnAttempt() {
        let desk = rememberedDesk()
        var attempt = StartupConnectionAttempt()
        XCTAssertNil(attempt.target)
        XCTAssertFalse(attempt.consume(id: desk.id))
        XCTAssertTrue(attempt.begin(enabled: true, rememberedDesk: desk,
                                    preview: false, verificationOnly: false))
        XCTAssertEqual(attempt.target, desk)
    }

    func testDisabledMissingDeskPreviewAndVerificationCannotBeActivatedLater() {
        let desk = rememberedDesk()
        let configurations: [(enabled: Bool, desk: RememberedDesk?, preview: Bool, verification: Bool)] = [
            (false, desk, false, false),
            (true, nil, false, false),
            (true, desk, true, false),
            (true, desk, false, true)
        ]
        for configuration in configurations {
            var attempt = StartupConnectionAttempt()
            XCTAssertFalse(attempt.begin(enabled: configuration.enabled, rememberedDesk: configuration.desk,
                                         preview: configuration.preview, verificationOnly: configuration.verification))
            XCTAssertNil(attempt.target)
            XCTAssertFalse(attempt.begin(enabled: true, rememberedDesk: desk,
                                         preview: false, verificationOnly: false))
            XCTAssertNil(attempt.target)
        }
    }

    func testAnotherDeviceCannotConsumeTheRememberedTarget() {
        let desk = rememberedDesk()
        var attempt = StartupConnectionAttempt()
        XCTAssertTrue(attempt.begin(enabled: true, rememberedDesk: desk,
                                    preview: false, verificationOnly: false))
        XCTAssertFalse(attempt.consume(id: UUID()))
        XCTAssertEqual(attempt.target, desk)
        XCTAssertTrue(attempt.consume(id: desk.id))
        XCTAssertNil(attempt.target)
    }

    func testRepeatedBeginCannotReplaceOrClearAnExistingTarget() {
        let first = rememberedDesk()
        let other = rememberedDesk()
        var attempt = StartupConnectionAttempt()
        XCTAssertTrue(attempt.begin(enabled: true, rememberedDesk: first,
                                    preview: false, verificationOnly: false))
        XCTAssertFalse(attempt.begin(enabled: true, rememberedDesk: other,
                                     preview: false, verificationOnly: false))
        XCTAssertFalse(attempt.begin(enabled: false, rememberedDesk: nil,
                                     preview: true, verificationOnly: true))
        XCTAssertEqual(attempt.target, first)
    }

    func testTargetCanOnlyBeConsumedOnceAndBeginCannotRearmIt() {
        let desk = rememberedDesk()
        var attempt = StartupConnectionAttempt()
        XCTAssertTrue(attempt.begin(enabled: true, rememberedDesk: desk,
                                    preview: false, verificationOnly: false))
        XCTAssertTrue(attempt.consume(id: desk.id))
        XCTAssertFalse(attempt.consume(id: desk.id))
        XCTAssertFalse(attempt.begin(enabled: true, rememberedDesk: desk,
                                     preview: false, verificationOnly: false))
        XCTAssertNil(attempt.target)
    }

    func testCancelBeforeOrAfterBeginPreventsAnyLaterAttempt() {
        let desk = rememberedDesk()
        var notStarted = StartupConnectionAttempt()
        notStarted.cancel()
        XCTAssertFalse(notStarted.begin(enabled: true, rememberedDesk: desk,
                                        preview: false, verificationOnly: false))
        XCTAssertNil(notStarted.target)

        var pending = StartupConnectionAttempt()
        XCTAssertTrue(pending.begin(enabled: true, rememberedDesk: desk,
                                    preview: false, verificationOnly: false))
        pending.cancel()
        pending.cancel()
        XCTAssertNil(pending.target)
        XCTAssertFalse(pending.consume(id: desk.id))
        XCTAssertFalse(pending.begin(enabled: true, rememberedDesk: desk,
                                     preview: false, verificationOnly: false))
    }

    private func rememberedDesk() -> RememberedDesk {
        RememberedDesk(id: UUID(), name: "测试升降桌")
    }

    @MainActor func testPreviewStartupLeavesHardwareAndMovementInactive() {
        let suite = "DeskLift.StartupPreviewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DeskConnectionPreferences(defaults: defaults)
        let desk = rememberedDesk()
        preferences.remember(desk)
        let model = DeskModel(preview: true, connectionPreferences: preferences)
        let originalStatus = model.status

        model.startAutomaticConnection()
        model.startAutomaticConnection()

        XCTAssertEqual(model.status, originalStatus)
        XCTAssertFalse(model.scanning)
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.ready)
        XCTAssertNil(model.height)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.motionID)
        XCTAssertEqual(preferences.lastDesk, desk)
    }

    @MainActor func testConnectionSettingPersistsWithoutStartingOrRestoringMotion() {
        let suite = "DeskLift.StartupSettingTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = DeskConnectionPreferences(defaults: defaults)
        let desk = rememberedDesk()
        preferences.remember(desk)
        let model = DeskModel(preview: true, memoryVerificationOnly: true,
                              connectionPreferences: preferences)

        model.setAutoConnectEnabled(false)
        XCTAssertFalse(model.autoConnectEnabled)
        XCTAssertFalse(DeskConnectionPreferences(defaults: defaults).autoConnectEnabled)
        model.setAutoConnectEnabled(true)
        model.startAutomaticConnection()

        XCTAssertTrue(preferences.autoConnectEnabled)
        XCTAssertEqual(preferences.lastDesk, desk)
        XCTAssertFalse(model.scanning)
        XCTAssertFalse(model.connecting)
        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.motionID)
        XCTAssertFalse(model.canMove)
    }
}
