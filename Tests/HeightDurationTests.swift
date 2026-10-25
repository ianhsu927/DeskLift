import Foundation
import XCTest

final class HeightDurationTests: XCTestCase {
    func testRepeatedFeedbackAtTheSameHeightKeepsTheOriginalStart() throws {
        var tracker = HeightDurationTracker()
        tracker.observe(height: 85.5, isMoving: false, now: 100)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 100)), 0)

        tracker.observe(height: 85.5, isMoving: false, now: 160)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 220)), 120)
    }

    func testSmallJitterDoesNotResetButCumulativeDriftDoes() throws {
        var tracker = HeightDurationTracker()
        tracker.observe(height: 85.5, isMoving: false, now: 0)
        tracker.observe(height: 85.6, isMoving: false, now: 30)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 30)), 30)

        tracker.observe(height: 85.699, isMoving: false, now: 60)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 60)), 60)

        // Each individual change is small, but the total change from the
        // stable reference has reached 0.2 cm.
        tracker.observe(height: 85.7, isMoving: false, now: 90)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 100)), 10)
    }

    func testThresholdIncludesBothDirectionsAndFloatingPointBoundary() throws {
        for (initial, changed) in [(85.5, 85.7), (85.5, 85.3), (0.1, 0.3)] {
            var tracker = HeightDurationTracker()
            tracker.observe(height: initial, isMoving: false, now: 10)
            tracker.observe(height: changed, isMoving: false, now: 50)
            XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 60)), 10,
                           "A 0.2 cm change must reset in either direction")
        }
    }

    func testMovementStopsTimingUntilAStationaryReadingArrives() throws {
        var tracker = HeightDurationTracker()
        tracker.observe(height: 85.5, isMoving: false, now: 100)
        tracker.observe(height: 85.5, isMoving: true, now: 150)
        XCTAssertNil(tracker.elapsed(at: 160))
        tracker.observe(height: 90, isMoving: true, now: 200)
        XCTAssertNil(tracker.elapsed(at: 210))

        tracker.observe(height: 90, isMoving: false, now: 220)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 280)), 60)
    }

    func testDisconnectDoesNotCarryDurationIntoReconnection() throws {
        var tracker = HeightDurationTracker()
        tracker.observe(height: 85.5, isMoving: false, now: 100)
        tracker.observe(height: nil, isMoving: false, now: 500)
        XCTAssertNil(tracker.elapsed(at: 800))

        tracker.observe(height: 85.5, isMoving: false, now: 1_000)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 1_005)), 5)
    }

    func testInvalidHeightClearsAnExistingInterval() throws {
        for invalidHeight in [-1.0, .nan, .infinity, -.infinity] {
            var tracker = HeightDurationTracker()
            tracker.observe(height: 85.5, isMoving: false, now: 100)
            tracker.observe(height: invalidHeight, isMoving: false, now: 160)
            XCTAssertNil(tracker.elapsed(at: 180))

            tracker.observe(height: 85.5, isMoving: false, now: 200)
            XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 205)), 5)
        }
    }

    func testInvalidObservationTimeClearsAnExistingInterval() throws {
        for invalidTime in [-1.0, .nan, .infinity, -.infinity] {
            var tracker = HeightDurationTracker()
            tracker.observe(height: 85.5, isMoving: false, now: 100)
            tracker.observe(height: 85.5, isMoving: false, now: invalidTime)
            XCTAssertNil(tracker.elapsed(at: 180))

            tracker.observe(height: 85.5, isMoving: false, now: 200)
            XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 205)), 5)
        }
    }

    func testClockRollbackRejectsOldQueriesAndRestartsOnObservation() throws {
        var tracker = HeightDurationTracker()
        tracker.observe(height: 85.5, isMoving: false, now: 100)
        tracker.observe(height: 85.5, isMoving: false, now: 150)
        XCTAssertNil(tracker.elapsed(at: 149))

        tracker.observe(height: 85.5, isMoving: false, now: 120)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 120)), 0)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 180)), 60)
    }

    func testElapsedRequiresAValidCurrentQueryAndAnObservedHeight() {
        var tracker = HeightDurationTracker()
        XCTAssertNil(tracker.elapsed(at: 10))
        tracker.observe(height: 85.5, isMoving: false, now: 10)
        for invalidTime in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertNil(tracker.elapsed(at: invalidTime))
        }
    }

    func testZeroHeightAndClockAreValid() throws {
        var tracker = HeightDurationTracker()
        tracker.observe(height: 0, isMoving: false, now: 0)
        XCTAssertEqual(try XCTUnwrap(tracker.elapsed(at: 60)), 60)
    }

    func testFormattingUsesCompletedMinutesAndPaddedHourRemainder() {
        XCTAssertEqual(HeightDurationTracker.format(0), "0 秒")
        XCTAssertEqual(HeightDurationTracker.format(59.999), "59 秒")
        XCTAssertEqual(HeightDurationTracker.format(60), "1 分钟")
        XCTAssertEqual(HeightDurationTracker.format(12 * 60 + 59), "12 分钟")
        XCTAssertEqual(HeightDurationTracker.format(3_599), "59 分钟")
        XCTAssertEqual(HeightDurationTracker.format(3_600), "1 小时 00 分钟")
        XCTAssertEqual(HeightDurationTracker.format(3_900), "1 小时 05 分钟")
        XCTAssertEqual(HeightDurationTracker.format(90_060), "25 小时 01 分钟")
    }

    func testFormattingInvalidAndExtremeValuesCannotOverflow() {
        for invalidTime in [-1.0, .nan, .infinity, -.infinity] {
            XCTAssertEqual(HeightDurationTracker.format(invalidTime), "—")
        }
        XCTAssertEqual(HeightDurationTracker.format(.greatestFiniteMagnitude), "超过 999999 小时")
    }
}
