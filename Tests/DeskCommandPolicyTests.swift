import Foundation
import XCTest

final class DeskCommandPolicyTests: XCTestCase {
    func testDecimalCalibrationUpperBoundRoundTripsWithoutAcceptingOutliers() {
        for base in [0.0, 62.01, 63.05, 64.99, 250] {
            let upper = base + 65
            XCTAssertEqual(DPI.raw(cm: upper, base: base), DPI.maxRaw)
            XCTAssertEqual(DPI.raw(cm: base, base: base), 0)
            XCTAssertNil(DPI.raw(cm: upper.nextUp, base: base))
            XCTAssertNil(DPI.raw(cm: base.nextDown, base: base))
        }
        XCTAssertEqual(DPI.raw(cm: 128.05, base: 63.05), DPI.maxRaw)
    }

    func testCurrentHeightUsesCalibrationAndAcceptsFreshnessBoundary() throws {
        var state = connectedState()
        state.feedbackAge = 1.5
        XCTAssertEqual(try state.currentHeight(), 85.5, accuracy: 0.000_001)

        state.baseHeight = 0
        state.rawHeight = 0
        state.feedbackAge = 0
        XCTAssertEqual(try state.currentHeight(), 0)

        state.baseHeight = 250
        state.rawHeight = DPI.maxRaw
        XCTAssertEqual(try state.currentHeight(), 315)
    }

    func testReadingHeightDoesNotRequireAStationaryDesk() throws {
        var state = connectedState()
        state.speed = -2
        state.canMove = false
        XCTAssertEqual(try state.currentHeight(), 85.5, accuracy: 0.000_001)
        assertError(.busy) { try state.target(height: 100) }
    }

    func testDisconnectedSnapshotCannotReadOrValidateMovement() {
        var state = connectedState()
        state.ready = false
        assertError(.notConnected) { try state.currentHeight() }
        assertError(.notConnected) { try state.target(height: 100) }
        assertError(.notConnected) { try state.target(preset: 4_000) }
    }

    func testOldNegativeAndNonfiniteFeedbackCannotReadOrMove() {
        for age in [Double(1.5).nextUp, -0.001, .nan, .infinity, -.infinity] {
            var state = connectedState()
            state.feedbackAge = age
            assertError(.staleFeedback) { try state.currentHeight() }
            assertError(.staleFeedback) { try state.target(height: 100) }
            assertError(.staleFeedback) { try state.target(preset: 4_000) }
        }
    }

    func testMissingAndInvalidCalibrationCannotReadOrMove() {
        let invalidBases: [Double?] = [nil, -0.001, 250.001, .nan, .infinity, -.infinity]
        for base in invalidBases {
            var state = connectedState()
            state.baseHeight = base
            assertError(.invalidHeight) { try state.currentHeight() }
            assertError(.invalidHeight) { try state.target(height: 100) }
            assertError(.invalidHeight) { try state.target(preset: 4_000) }
        }
    }

    func testMissingAndInvalidRawFeedbackCannotReadOrMove() {
        let invalidRawPositions: [Int?] = [nil, -1, DPI.maxRaw + 1, Int.max, Int.min]
        for raw in invalidRawPositions {
            var state = connectedState()
            state.rawHeight = raw
            assertError(.invalidHeight) { try state.currentHeight() }
            assertError(.invalidHeight) { try state.target(height: 100) }
            assertError(.invalidHeight) { try state.target(preset: 4_000) }
        }
    }

    func testHeightTargetsUseProtocolConversionAndBothTravelLimits() throws {
        let state = connectedState()
        XCTAssertEqual(try state.target(height: 64), 0)
        XCTAssertEqual(try state.target(height: 129), DPI.maxRaw)
        XCTAssertEqual(try state.target(height: 85.556), 2_156)
    }

    func testHeightTargetsJustOutsideLimitsAreRejectedWithoutClamping() {
        let state = connectedState()
        for height in [63.999, 129.001, -Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude] {
            assertError(.invalidHeight) { try state.target(height: height) }
        }
    }

    func testNonfiniteHeightTargetsAreRejected() {
        let state = connectedState()
        for height in [Double.nan, .infinity, -.infinity] {
            assertError(.invalidHeight) { try state.target(height: height) }
        }
    }

    func testUnavailableMovementAndMovingOrInvalidSpeedRejectBothTargetKinds() {
        var state = connectedState()
        state.canMove = false
        assertError(.busy) { try state.target(height: 100) }
        assertError(.busy) { try state.target(preset: 4_000) }

        state.canMove = true
        for speed in [0.1, -0.1, 2, -2, .nan, .infinity, -.infinity] {
            state.speed = speed
            assertError(.busy) { try state.target(height: 100) }
            assertError(.busy) { try state.target(preset: 4_000) }
        }
    }

    func testStationarySpeedToleranceMatchesDeskModel() throws {
        for speed in [0.0, 0.099, -0.099] {
            var state = connectedState()
            state.speed = speed
            XCTAssertEqual(try state.target(height: 100), 3_600)
            XCTAssertEqual(try state.target(preset: 4_000), 4_000)
        }
    }

    func testPresetMustExistAndFitProtocolTravel() throws {
        let state = connectedState()
        assertError(.presetMissing) { try state.target(preset: nil) }
        for raw in [-1, DPI.maxRaw + 1, Int.min, Int.max] {
            assertError(.invalidHeight) { try state.target(preset: raw) }
        }
        XCTAssertEqual(try state.target(preset: 0), 0)
        XCTAssertEqual(try state.target(preset: DPI.maxRaw), DPI.maxRaw)
    }

    func testConfirmedTargetMustPassValidationAtCreation() {
        let sessionID = UUID()
        var state = connectedState()
        state.ready = false
        assertError(.notConnected) { try DeskCommandTarget(raw: 4_000, state: state, sessionID: sessionID) }

        state = connectedState()
        state.feedbackAge = 2
        assertError(.staleFeedback) { try DeskCommandTarget(raw: 4_000, state: state, sessionID: sessionID) }

        state = connectedState()
        state.canMove = false
        assertError(.busy) { try DeskCommandTarget(raw: 4_000, state: state, sessionID: sessionID) }

        state = connectedState()
        assertError(.invalidHeight) { try DeskCommandTarget(raw: DPI.maxRaw + 1, state: state, sessionID: sessionID) }
    }

    func testConfirmedTargetRejectsAnotherConnectionBeforeOtherStateChecks() throws {
        let state = connectedState()
        let target = try DeskCommandTarget(raw: 4_000, state: state, sessionID: UUID())
        var changedState = state
        changedState.ready = false
        changedState.feedbackAge = 2
        assertError(.contextChanged) { try target.validatedRaw(in: changedState, sessionID: UUID()) }
    }

    func testConfirmedTargetRejectsChangedOrMissingCalibration() throws {
        let sessionID = UUID()
        let target = try DeskCommandTarget(raw: 4_000, state: connectedState(), sessionID: sessionID)
        let changedBases: [Double?] = [Double(64).nextUp, 63.05, nil, .nan, .infinity]
        for base in changedBases {
            var changedState = connectedState()
            changedState.baseHeight = base
            assertError(.contextChanged) { try target.validatedRaw(in: changedState, sessionID: sessionID) }
        }
    }

    func testConfirmedTargetRechecksFreshnessAndMovementReadiness() throws {
        let sessionID = UUID()
        let target = try DeskCommandTarget(raw: 4_000, state: connectedState(), sessionID: sessionID)
        var state = connectedState()
        state.feedbackAge = Double(1.5).nextUp
        assertError(.staleFeedback) { try target.validatedRaw(in: state, sessionID: sessionID) }

        state = connectedState()
        state.canMove = false
        assertError(.busy) { try target.validatedRaw(in: state, sessionID: sessionID) }

        state = connectedState()
        state.speed = 0.1
        assertError(.busy) { try target.validatedRaw(in: state, sessionID: sessionID) }

        state = connectedState()
        state.ready = false
        assertError(.notConnected) { try target.validatedRaw(in: state, sessionID: sessionID) }

        // New current feedback is expected while a user confirms the target.
        state = connectedState()
        state.rawHeight = 3_000
        state.feedbackAge = 1.5
        XCTAssertEqual(try target.validatedRaw(in: state, sessionID: sessionID), 4_000)
        XCTAssertEqual(target.height, 104)
    }

    func testConfirmedPresetRejectsChangedOrRemovedSlot() throws {
        let target = try DeskCommandTarget(raw: 4_000, state: connectedState(), sessionID: UUID())
        XCTAssertNoThrow(try target.validatePreset(4_000))
        assertError(.presetChanged) { try target.validatePreset(4_001) }
        assertError(.presetChanged) { try target.validatePreset(nil) }
    }

    func testDecimalCalibrationRetainsTopRawTargetWithoutHeightRoundTrip() throws {
        var state = connectedState()
        state.baseHeight = 63.05
        let sessionID = UUID()
        let target = try DeskCommandTarget(raw: 6_500, state: state, sessionID: sessionID)

        XCTAssertEqual(target.raw, 6_500)
        XCTAssertEqual(target.height, 128.05, accuracy: 0.000_000_001)
        XCTAssertEqual(target.baseHeight, 63.05)
        XCTAssertEqual(target.sessionID, sessionID)
        XCTAssertEqual(try target.validatedRaw(in: state, sessionID: sessionID), 6_500)
        XCTAssertNoThrow(try target.validatePreset(6_500))
    }

    private func connectedState() -> DeskCommandState {
        DeskCommandState(ready: true, rawHeight: 2_150, baseHeight: 64,
                         speed: 0, canMove: true, feedbackAge: 0.2)
    }

    private func assertError<T>(_ expected: DeskCommandError, file: StaticString = #filePath,
                                line: UInt = #line, operation: () throws -> T) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            XCTAssertEqual(error as? DeskCommandError, expected, file: file, line: line)
        }
    }
}
