import XCTest

final class DeskLiftProtocolTests: XCTestCase {
    func testProtocolAndMovementSafety() throws {
        let checks = try runProtocolSafetyChecks()
        XCTAssertEqual(checks, 18, "All protocol and movement safety checks must run")
    }
}
