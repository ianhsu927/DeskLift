import XCTest

final class ControllerMemoryReadOnlyTests: XCTestCase {
    @MainActor func testNormalModeRetainsExistingMovementEligibility() {
        let model = DeskModel(preview: true)
        model.ready = true
        model.baseHeight = 62
        model.rawHeight = 600
        model.speed = 0
        XCTAssertFalse(model.memoryVerificationOnly)
        XCTAssertTrue(model.canMove)
        XCTAssertFalse(model.canVerifyControllerMemory)
        // Do not start a movement: this is an eligibility assertion only.
    }

    @MainActor func testVerificationModeBlocksEveryMovementAndPresetWriteEntry() {
        // Preview never creates a Bluetooth manager. Fake published state only
        // verifies the read-only gate; this test cannot address real hardware.
        let model = DeskModel(preview: true, memoryVerificationOnly: true)
        model.ready = true
        model.baseHeight = 62
        model.rawHeight = 600
        model.speed = 0
        model.targetText = "105.5"
        model.presets = [4_350, nil]

        XCTAssertFalse(model.canMove)
        model.hold(up: true)
        model.hold(up: false)
        model.goToTarget()
        model.recallPreset(0)
        model.savePreset(0)
        model.savePreset(1)

        XCTAssertFalse(model.isActive)
        XCTAssertNil(model.motionID)
        XCTAssertEqual(model.presets, [4_350, nil])
        XCTAssertEqual(model.baseHeight, 62)
        XCTAssertEqual(model.rawHeight, 600)
    }

    @MainActor func testReadOnlyModeStillAllowsSafeStopWithoutHardware() {
        let model = DeskModel(preview: true, memoryVerificationOnly: true)
        XCTAssertFalse(model.shortcutStop())
        XCTAssertFalse(model.isActive)
        XCTAssertFalse(model.memoryVerificationRunning)
        XCTAssertFalse(model.canMove)
    }

    @MainActor func testMemoryWritesRequireLoadedDeviceSnapshotBeforePresentingConfirmation() {
        let model = DeskModel(preview: true)
        model.ready = true
        model.baseHeight = 62
        model.rawHeight = 600
        model.speed = 0
        model.presets = [629, 4_349]
        XCTAssertFalse(model.canWriteControllerMemory)
        model.requestControllerMemoryWrite(slot: 3, heightText: "105.49")
        model.requestControllerMemoryWrite(slot: 0, heightText: nil)
        XCTAssertFalse(model.controllerMemoryBusy)
        XCTAssertFalse(model.canCancelControllerMemory)
        XCTAssertTrue(model.controllerMemoryRows.allSatisfy { !$0.isLoaded })
        XCTAssertEqual(model.presets, [629, 4_349])
    }

    @MainActor func testVerificationModeCannotStartProductionMemoryReadOrWrite() {
        let model = DeskModel(preview: true, memoryVerificationOnly: true)
        model.ready = true
        model.baseHeight = 62
        model.rawHeight = 600
        XCTAssertFalse(model.canRefreshControllerMemory)
        XCTAssertFalse(model.canWriteControllerMemory)
        model.refreshControllerMemory()
        model.requestControllerMemoryWrite(slot: 3, heightText: "68")
        XCTAssertFalse(model.controllerMemoryBusy)
        XCTAssertFalse(model.canMove)
    }

    @MainActor func testCalibrationChangeBeforeFirstMemorySendCannotRestoreOldMovementEligibility() {
        let model = connectedPreviewModel()
        model.refreshControllerMemory()
        XCTAssertTrue(model.controllerMemoryBusy)
        XCTAssertFalse(model.canMove)
        model.receiveControllerConfiguration(Data([1, 3, 1, 0x9c, 0x18])) // 63 cm, during initial drain
        XCTAssertFalse(model.controllerMemoryBusy)
        XCTAssertFalse(model.canMove)
        XCTAssertFalse(model.canRefreshControllerMemory)
        XCTAssertNil(model.height)
        XCTAssertThrowsError(try model.shortcutHeight())
        XCTAssertTrue(model.controllerMemoryRows.allSatisfy { !$0.isLoaded })
    }

    @MainActor func testAmbiguousCalibrationBeforeFirstSendFailsClosed() {
        let model = connectedPreviewModel()
        model.refreshControllerMemory()
        model.receiveControllerConfiguration(Data([1, 3, 1, 1, 0]))
        XCTAssertFalse(model.controllerMemoryBusy)
        XCTAssertFalse(model.canMove)
        XCTAssertNil(model.height)
        XCTAssertEqual(model.baseHeight, 62) // never install a false 0.01 cm base
    }

    @MainActor func testCancelBeforeAnyReadIsSentDoesNotPoisonTheConnection() {
        let model = connectedPreviewModel()
        model.refreshControllerMemory()
        model.cancelControllerMemoryOperation()
        XCTAssertFalse(model.controllerMemoryBusy)
        XCTAssertTrue(model.canMove)
        XCTAssertTrue(model.canRefreshControllerMemory)
        XCTAssertEqual(model.height, 68)
    }

    @MainActor func testInvalidFeedbackDuringInitialMemoryDrainCannotAllowAWrite() {
        let model = connectedPreviewModel()
        model.refreshControllerMemory()
        model.receiveHeightFeedback(Data([0xff]))
        XCTAssertFalse(model.controllerMemoryBusy)
        XCTAssertFalse(model.canMove)
        XCTAssertFalse(model.canWriteControllerMemory)
        XCTAssertNil(model.height)
    }

    @MainActor private func connectedPreviewModel() -> DeskModel {
        let model = DeskModel(preview: true)
        model.ready = true
        model.baseHeight = 62
        model.receiveHeightFeedback(Data([0x58, 0x02, 0, 0])) // raw 600, stationary
        XCTAssertTrue(model.canRefreshControllerMemory)
        return model
    }
}
