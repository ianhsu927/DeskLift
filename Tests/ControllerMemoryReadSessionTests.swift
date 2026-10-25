import Foundation
import XCTest

final class ControllerMemoryReadSessionTests: XCTestCase {
    func testFullSequenceRespectsDrainsAndKeepsBothRounds() throws {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        XCTAssertNil(session.nextCommand(at: 0.625))
        var now = 0.75
        let commands = [DPI.readBase]
            + (0...3).map { ControllerMemoryProtocol.read(slot: $0)! }
            + (0...3).map { ControllerMemoryProtocol.read(slot: $0)! }
            + [DPI.readBase]

        for (step, command) in commands.enumerated() {
            XCTAssertEqual(session.nextCommand(at: now), command)
            session.didSend(at: now)
            XCTAssertNil(session.nextCommand(at: now))
            let receivedAt = now + 0.125
            let frame = step == 0 || step == 9 ? baseFrame() : slotFrame((step - 1) % 4)
            session.receive(frame, at: receivedAt)
            if step < 9 {
                let delay = step == 4 ? 0.75 : 0.25
                XCTAssertNil(session.nextCommand(at: receivedAt + delay - 0.125))
                now = receivedAt + delay
            }
        }

        XCTAssertTrue(session.isFinished)
        XCTAssertNil(session.failure)
        for slot in 0...3 {
            let first = try XCTUnwrap(session.replies[0][slot])
            let second = try XCTUnwrap(session.replies[1][slot])
            XCTAssertEqual(first.rawFrame, slotFrame(slot))
            XCTAssertEqual(first.state, second.state)
        }
        XCTAssertEqual(session.trace.filter { $0.contains(" TX ") }.count, 10)
        XCTAssertEqual(session.trace.filter { $0.contains(" RX ") }.count, 10)
        XCTAssertTrue(session.trace.contains { $0.contains("TX base-before: 7F 81 00") })
        XCTAssertTrue(session.trace.contains { $0.contains("RX round-1 slot-1: 01 03 01 01 00") })
        let completedReplies = session.replies
        XCTAssertNil(session.nextCommand(at: 100))
        session.receive(slotFrame(0), at: 101)
        XCTAssertEqual(session.replies, completedReplies)
        XCTAssertNil(session.failure)
        XCTAssertTrue(session.trace.last?.contains("RX ignored after finish") == true)
    }

    func testBackpressureKeepsTheSameCommandAndNeverCreatesEmptySlots() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        XCTAssertEqual(session.nextCommand(at: 0.75), DPI.readBase)
        XCTAssertEqual(session.nextCommand(at: 1.75), DPI.readBase)
        XCTAssertEqual(session.nextCommand(at: 3.625), DPI.readBase)
        XCTAssertFalse(session.isFinished)
        XCTAssertFalse(session.trace.contains { $0.contains(" TX ") })
        session.poll(at: 3.75)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.failure?.contains("发送等待") == true)
        XCTAssertTrue(session.replies.joined().allSatisfy { $0 == nil })
        XCTAssertNil(session.nextCommand(at: 4))
    }

    func testReplyDeadlineStartsAtActualSendAndUnknownFramesCannotExtendIt() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        XCTAssertEqual(session.nextCommand(at: 0.75), DPI.readBase)
        session.didSend(at: 3.5)
        session.didSend(at: 4)
        session.receive(Data([0xff, 0x00]), at: 6.25)
        session.poll(at: 6.375)
        XCTAssertFalse(session.isFinished)
        session.receive(baseFrame(), at: 6.5)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.failure?.contains("应答等待") == true)
        XCTAssertTrue(session.replies.joined().allSatisfy { $0 == nil })
        XCTAssertNil(session.nextCommand(at: 7))
    }

    func testRepliesWithoutAnActualSendNeverAdvanceTheRequest() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        session.receive(baseFrame(), at: 0.5)
        XCTAssertEqual(session.nextCommand(at: 0.75), DPI.readBase)
        session.receive(baseFrame(), at: 1)
        XCTAssertEqual(session.nextCommand(at: 1), DPI.readBase)
        session.didSend(at: 1)
        session.receive(baseFrame(), at: 1.125)
        XCTAssertEqual(session.nextCommand(at: 1.375), ControllerMemoryProtocol.read(slot: 0))
        XCTAssertFalse(session.isFinished)
    }

    func testWrongSlotsUnknownFramesAndDrainPeriodLateRepliesDoNotAdvance() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        let firstSlotAt = beginSlots(&session)
        session.didSend(at: firstSlotAt)
        session.receive(slotFrame(1), at: 1.25)
        session.receive(Data([0xff]), at: 1.375)
        XCTAssertNil(session.replies[0][0])
        XCTAssertNil(session.nextCommand(at: 1.375))
        session.receive(slotFrame(0), at: 1.5)
        session.receive(slotFrame(0), at: 1.625)
        XCTAssertNil(session.replies[0][1])
        XCTAssertEqual(session.nextCommand(at: 1.75), ControllerMemoryProtocol.read(slot: 1))
        session.didSend(at: 1.75)
        session.receive(baseFrame(), at: 1.875)
        XCTAssertNil(session.replies[0][1])
        session.receive(slotFrame(1), at: 2)
        XCTAssertEqual(session.replies[0][1]?.state, .empty)
        XCTAssertEqual(session.nextCommand(at: 2.25), ControllerMemoryProtocol.read(slot: 2))
        XCTAssertFalse(session.isFinished)
    }

    func testWrongSlotRepliesCannotExtendSlotDeadlineAndLateValidReplyIsIgnored() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        let firstSlotAt = beginSlots(&session)
        session.didSend(at: firstSlotAt)
        session.receive(slotFrame(1), at: firstSlotAt + 2.75)
        session.receive(Data(), at: firstSlotAt + 2.875)
        session.poll(at: firstSlotAt + 3)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.failure?.contains("应答等待") == true)
        session.receive(slotFrame(0), at: firstSlotAt + 3.125)
        XCTAssertNil(session.replies[0][0])
        XCTAssertNil(session.nextCommand(at: firstSlotAt + 4))
    }

    func testChangedInitialCalibrationFinishesWithoutReadingSlots() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        XCTAssertEqual(session.nextCommand(at: 0.75), DPI.readBase)
        session.didSend(at: 0.75)
        session.receive(baseFrame(cents: 6_401), at: 0.875)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.failure?.contains("高度基准改变") == true)
        XCTAssertNil(session.nextCommand(at: 1.125))
        XCTAssertTrue(session.replies.joined().allSatisfy { $0 == nil })
    }

    func testChangedFinalCalibrationFailsEvenAfterTwoMatchingRounds() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        let finalBaseAt = finishSlotRounds(&session)
        XCTAssertEqual(session.nextCommand(at: finalBaseAt), DPI.readBase)
        session.didSend(at: finalBaseAt)
        session.receive(baseFrame(cents: 6_300), at: finalBaseAt + 0.125)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.failure?.contains("高度基准改变") == true)
        XCTAssertTrue(session.replies.joined().allSatisfy { $0 != nil })
        XCTAssertNil(session.nextCommand(at: finalBaseAt + 1))
    }

    func testSecondRoundRequiresMatchingValueStateAndMetadata() {
        let changedFrames = [
            candidateFrame(slot: 0, raw: 1, metadata: [1, 0]),
            candidateFrame(slot: 0, raw: 0, metadata: [1, 1]),
            Data([1, 3, 0, 1, 0])
        ]
        for changed in changedFrames {
            var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
            var now = beginSlots(&session)
            for slot in 0...3 {
                XCTAssertEqual(session.nextCommand(at: now), ControllerMemoryProtocol.read(slot: slot))
                session.didSend(at: now)
                session.receive(slotFrame(slot), at: now + 0.125)
                now += 0.125 + (slot == 3 ? 0.75 : 0.25)
            }
            XCTAssertEqual(session.nextCommand(at: now), ControllerMemoryProtocol.read(slot: 0))
            session.didSend(at: now)
            session.receive(changed, at: now + 0.125)
            XCTAssertTrue(session.isFinished)
            XCTAssertTrue(session.failure?.contains("两轮读取不一致") == true)
            XCTAssertNotEqual(session.replies[0][0]?.state, session.replies[1][0]?.state)
            XCTAssertNil(session.nextCommand(at: now + 1))
        }
    }

    func testInvalidInputsAndClockRollbackEndTheSession() {
        for base in [-0.01, 250.01, Double.nan, .infinity] {
            let session = ControllerMemoryReadSession(expectedBase: base, now: 0)
            XCTAssertTrue(session.isFinished)
            XCTAssertNotNil(session.failure)
        }
        for now in [-1.0, Double.nan, .infinity] {
            let session = ControllerMemoryReadSession(expectedBase: 64, now: now)
            XCTAssertTrue(session.isFinished)
            XCTAssertNotNil(session.failure)
        }
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 1)
        XCTAssertEqual(session.nextCommand(at: 1.75), DPI.readBase)
        session.poll(at: 1.5)
        XCTAssertTrue(session.isFinished)
        XCTAssertTrue(session.failure?.contains("时钟") == true)
        XCTAssertNil(session.nextCommand(at: 2))
    }

    func testSendingBeforeTheDrainFinishesFailsClosed() {
        var session = ControllerMemoryReadSession(expectedBase: 64, now: 0)
        session.didSend(at: 0.5)
        XCTAssertTrue(session.isFinished)
        XCTAssertNotNil(session.failure)
        XCTAssertNil(session.nextCommand(at: 0.75))
    }

    private func beginSlots(_ session: inout ControllerMemoryReadSession) -> TimeInterval {
        XCTAssertEqual(session.nextCommand(at: 0.75), DPI.readBase)
        session.didSend(at: 0.75)
        session.receive(baseFrame(), at: 0.875)
        XCTAssertFalse(session.isFinished)
        XCTAssertEqual(session.nextCommand(at: 1.125), ControllerMemoryProtocol.read(slot: 0))
        return 1.125
    }

    private func finishSlotRounds(_ session: inout ControllerMemoryReadSession) -> TimeInterval {
        var now = beginSlots(&session)
        for round in 0...1 {
            for slot in 0...3 {
                XCTAssertEqual(session.nextCommand(at: now), ControllerMemoryProtocol.read(slot: slot))
                session.didSend(at: now)
                session.receive(slotFrame(slot), at: now + 0.125)
                XCTAssertFalse(session.isFinished)
                now += 0.125 + (round == 0 && slot == 3 ? 0.75 : 0.25)
            }
        }
        return now
    }

    private func baseFrame(cents: Int = 6_400) -> Data {
        Data([1, 3, 1, UInt8(cents & 255), UInt8(cents >> 8)])
    }

    private func slotFrame(_ slot: Int) -> Data {
        switch slot {
        case 0: return candidateFrame(slot: slot, raw: 0, metadata: [1, 0])
        case 1: return Data([1, 3, 1, 1, 0])
        case 2: return candidateFrame(slot: slot, raw: 6_500, metadata: [1, 1])
        default: return candidateFrame(slot: slot, raw: 2_150, metadata: [0, 0])
        }
    }

    private func candidateFrame(slot: Int, raw: Int, metadata: [UInt8]) -> Data {
        Data([1, 5, UInt8(slot)] + metadata + [UInt8(raw & 255), UInt8(raw >> 8)])
    }
}
