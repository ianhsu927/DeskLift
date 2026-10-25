import AppKit
import CoreFoundation
import XCTest

final class HoldButtonTests: XCTestCase {
    @MainActor
    func testDisabledButtonCannotStartMovement() {
        let button = HoldButton(title: "测试", target: nil, action: nil)
        var presses = 0
        var releases = 0
        button.press = { presses += 1 }
        button.release = { releases += 1 }

        button.allowed = false
        button.isEnabled = true
        XCTAssertFalse(button.accessibilityPerformPress())
        button.allowed = true
        button.isEnabled = false
        XCTAssertFalse(button.accessibilityPerformPress())
        button.finish()

        XCTAssertEqual(presses, 0)
        XCTAssertEqual(releases, 0)
    }

    @MainActor
    func testDraggingIntoButtonWithoutMouseDownDoesNotStartMovement() throws {
        let button = enabledButton()
        button.frame = NSRect(x: 0, y: 0, width: 80, height: 30)
        var presses = 0
        var releases = 0
        button.press = { presses += 1 }
        button.release = { releases += 1 }

        // This event is only passed directly to the view, never posted to the
        // system. Non-sticky menus may deliver a drag before any mouseDown.
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 12, y: 12),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        button.mouseDragged(with: event)

        XCTAssertEqual(presses, 0)
        XCTAssertEqual(releases, 0)
    }

    @MainActor
    func testAccessibilityPulseReleasesDuringMenuTracking() {
        let button = enabledButton()
        var presses = 0
        var releases = 0
        var releasedAt: TimeInterval?
        button.press = { presses += 1 }
        button.release = {
            releases += 1
            releasedAt = ProcessInfo.processInfo.systemUptime
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(releases, 0)
        runMenuTracking(for: 0.6)

        XCTAssertEqual(releases, 1)
        if let releasedAt {
            XCTAssertGreaterThanOrEqual(releasedAt - startedAt, 0.15)
            XCTAssertLessThan(releasedAt - startedAt, 0.5)
        } else {
            XCTFail("The pulse must release while the menu tracking mode is running")
        }
        button.finish()
        XCTAssertEqual(releases, 1)
    }

    @MainActor
    func testFinishReleasesOnceAndCancelsPendingPulse() {
        let button = enabledButton()
        var releases = 0
        button.release = { releases += 1 }

        XCTAssertTrue(button.accessibilityPerformPress())
        button.finish()
        button.finish()
        XCTAssertEqual(releases, 1)
        runMenuTracking(for: 0.35)
        XCTAssertEqual(releases, 1, "A closed menu must not retain a second delayed release")
    }

    @MainActor
    func testMovingOutOfWindowFinishesPendingPulse() {
        let button = enabledButton()
        var releases = 0
        button.release = { releases += 1 }

        XCTAssertTrue(button.accessibilityPerformPress())
        XCTAssertNil(button.window)
        button.viewDidMoveToWindow()
        XCTAssertEqual(releases, 1)
        runMenuTracking(for: 0.35)
        XCTAssertEqual(releases, 1)
    }

    @MainActor
    private func enabledButton() -> HoldButton {
        let button = HoldButton(title: "测试", target: nil, action: nil)
        button.allowed = true
        button.isEnabled = true
        return button
    }

    @MainActor
    private func runMenuTracking(for duration: TimeInterval) {
        let mode = RunLoop.Mode.eventTracking
        // A hostless XCTest process has not necessarily initialized AppKit's
        // common modes. Reproduce Cocoa's default event-tracking membership
        // without creating NSApplication, windows, input events, or Bluetooth.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(rawValue: mode.rawValue as CFString))
        var finished = false
        let deadline = Timer(timeInterval: duration, repeats: false) { _ in finished = true }
        RunLoop.main.add(deadline, forMode: mode)
        while !finished {
            _ = RunLoop.main.run(mode: mode, before: Date(timeIntervalSinceNow: duration + 1))
        }
        deadline.invalidate()
    }
}
