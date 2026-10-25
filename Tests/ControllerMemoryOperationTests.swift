import Foundation
import XCTest

final class ControllerMemoryOperationTests: XCTestCase {
    func testReadAllRequiresTwoMatchingRoundsAndFinalQuietDrain() {
        var operation = ControllerMemoryOperation(kind: .readAll, expectedBase: 64, now: 0)
        XCTAssertNil(operation.nextCommand(at: 0.625))
        var now = begin(&operation)
        for round in 0...1 {
            for slot in 0...3 {
                XCTAssertEqual(operation.nextCommand(at: now), ControllerMemoryProtocol.read(slot: slot))
                operation.didSend(at: now)
                operation.receive(slotFrame(slot), at: now + 0.125)
                XCTAssertFalse(operation.isFinished)
                let delay = round == 0 && slot == 3 ? 0.75 : 0.25
                XCTAssertNil(operation.nextCommand(at: now + 0.125 + delay - 0.125))
                now += 0.125 + delay
            }
        }
        verifyFinalBaseAndDrain(&operation, at: now)
        XCTAssertNil(operation.failure)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertTrue(operation.replies.allSatisfy { $0?.isRecognizedStorageReply == true })
        XCTAssertEqual(operation.trace.filter { $0.contains(" TX ") }.count, 10)
        XCTAssertFalse(operation.trace.contains { $0.contains("TX save-once") })
    }

    func testReadAllRejectsChangedSecondRoundWithoutWriting() {
        var operation = ControllerMemoryOperation(kind: .readAll, expectedBase: 64, now: 0)
        var now = begin(&operation)
        for slot in 0...3 {
            XCTAssertEqual(operation.nextCommand(at: now), ControllerMemoryProtocol.read(slot: slot))
            operation.didSend(at: now)
            operation.receive(slotFrame(slot), at: now + 0.125)
            now += 0.125 + (slot == 3 ? 0.75 : 0.25)
        }
        XCTAssertEqual(operation.nextCommand(at: now), ControllerMemoryProtocol.read(slot: 0))
        operation.didSend(at: now)
        operation.receive(valueFrame(slot: 0, raw: 1), at: now + 0.125)
        XCTAssertTrue(operation.isFinished)
        XCTAssertTrue(operation.failure?.contains("两轮读取不一致") == true)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertNil(operation.nextCommand(at: now + 1))
    }

    func testSaveIsSentOnceAndRequiresTwoExplicitMatchingReads() {
        var operation = saveOperation()
        let writeAt = prepareWrite(&operation)
        let command = Data([0x7f, 0x99, 0x80, 2, 1, 1, 0x66, 0x08])
        XCTAssertEqual(operation.nextCommand(at: writeAt), command)
        XCTAssertNil(operation.nextCommand(at: writeAt))
        operation.didSend(at: writeAt)
        XCTAssertTrue(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        operation.receive(valueFrame(slot: 2, raw: 2_150), at: writeAt + 0.125)
        XCTAssertNil(operation.nextCommand(at: writeAt + 0.625))
        let firstReadAt = writeAt + 0.75
        XCTAssertEqual(operation.nextCommand(at: firstReadAt), ControllerMemoryProtocol.read(slot: 2))
        operation.didSend(at: firstReadAt)
        operation.receive(valueFrame(slot: 2, raw: 2_150), at: firstReadAt + 0.125)
        XCTAssertNil(operation.nextCommand(at: firstReadAt + 0.75))
        let secondReadAt = firstReadAt + 0.875
        XCTAssertEqual(operation.nextCommand(at: secondReadAt), ControllerMemoryProtocol.read(slot: 2))
        operation.didSend(at: secondReadAt)
        operation.receive(valueFrame(slot: 2, raw: 2_150), at: secondReadAt + 0.125)
        verifyFinalBaseAndDrain(&operation, at: secondReadAt + 0.375)
        XCTAssertNil(operation.failure)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertEqual(operation.replies[2]?.confirmedRaw, 2_150)
        XCTAssertEqual(operation.trace.filter { $0.contains("TX save-once:") }.count, 1)
        XCTAssertEqual(operation.trace.filter { $0.contains(" TX ") }.count, 7)
        XCTAssertNil(operation.nextCommand(at: 100))
    }

    func testChangedPreviousValuePreventsThePersistentWrite() {
        var operation = saveOperation(previous: .candidate(raw: 1_000, metadata: [1, 1]))
        let now = begin(&operation)
        XCTAssertEqual(operation.nextCommand(at: now), ControllerMemoryProtocol.read(slot: 2))
        operation.didSend(at: now)
        operation.receive(emptyFrame(slot: 2), at: now + 0.125)
        XCTAssertTrue(operation.isFinished)
        XCTAssertTrue(operation.failure?.contains("原档位已改变") == true)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertNil(operation.nextCommand(at: now + 1))
    }

    func testFailedWriteSendEndsImmediatelyWithoutRetry() {
        var operation = saveOperation()
        let now = prepareWrite(&operation)
        XCTAssertEqual(operation.nextCommand(at: now), ControllerMemoryProtocol.save(slot: 2, raw: 2_150))
        operation.didFailToSend(at: now)
        XCTAssertTrue(operation.isFinished)
        XCTAssertNotNil(operation.failure)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertNil(operation.nextCommand(at: now))
        XCTAssertNil(operation.nextCommand(at: now + 100))
        XCTAssertFalse(operation.trace.contains { $0.contains("TX save-once:") })
    }

    func testOfferedWriteCannotBeRetrievedOrRenewedWhileCallerWaits() {
        var operation = saveOperation()
        let now = prepareWrite(&operation)
        XCTAssertNotNil(operation.nextCommand(at: now))
        XCTAssertNil(operation.nextCommand(at: now + 1))
        XCTAssertNil(operation.nextCommand(at: now + 2.875))
        operation.poll(at: now + 3)
        XCTAssertTrue(operation.isFinished)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertNil(operation.nextCommand(at: now + 4))
    }

    func testBackpressureOnlyRetriesReadsAndDoesNotCreateAReplyContext() {
        var operation = ControllerMemoryOperation(kind: .readAll, expectedBase: 64, now: 0)
        XCTAssertEqual(operation.nextCommand(at: 0.75), DPI.readBase)
        operation.didFailToSend(at: 0.75)
        operation.receive(baseFrame(), at: 1)
        XCTAssertEqual(operation.nextCommand(at: 1.5), DPI.readBase)
        operation.didFailToSend(at: 2)
        operation.poll(at: 3.625)
        XCTAssertFalse(operation.isFinished)
        operation.poll(at: 3.75)
        XCTAssertTrue(operation.isFinished)
        XCTAssertTrue(operation.failure?.contains("发送等待") == true)
        XCTAssertTrue(operation.replies.allSatisfy { $0 == nil })
        XCTAssertFalse(operation.outcomeUncertain)
    }

    func testUnknownWrongSlotAndMetadataCannotAdvanceOrExtendReadDeadline() {
        var operation = ControllerMemoryOperation(kind: .readAll, expectedBase: 64, now: 0)
        let now = begin(&operation)
        operation.didSend(at: now)
        operation.receive(slotFrame(2), at: now + 0.25)
        operation.receive(valueFrame(slot: 0, raw: 0, metadata: [1, 0]), at: now + 2.5)
        operation.receive(Data([0xff]), at: now + 2.875)
        XCTAssertNil(operation.replies[0])
        XCTAssertNil(operation.nextCommand(at: now + 2.875))
        operation.receive(slotFrame(0), at: now + 3)
        XCTAssertTrue(operation.isFinished)
        XCTAssertTrue(operation.failure?.contains("应答等待") == true)
        XCTAssertNil(operation.replies[0])
        XCTAssertFalse(operation.outcomeUncertain)
    }

    func testWriteReadbackMismatchAndTimeoutAreUncertainWithoutRollback() {
        for frame in [valueFrame(slot: 2, raw: 2_151), emptyFrame(slot: 2)] {
            var operation = saveOperation()
            let writeAt = prepareWrite(&operation)
            XCTAssertNotNil(operation.nextCommand(at: writeAt))
            operation.didSend(at: writeAt)
            let readAt = writeAt + 0.75
            XCTAssertEqual(operation.nextCommand(at: readAt), ControllerMemoryProtocol.read(slot: 2))
            operation.didSend(at: readAt)
            operation.receive(frame, at: readAt + 0.125)
            assertUncertainFinished(operation)
            XCTAssertEqual(operation.trace.filter { $0.contains("TX save-once:") }.count, 1)
        }
        var operation = saveOperation()
        let writeAt = prepareWrite(&operation)
        XCTAssertNotNil(operation.nextCommand(at: writeAt))
        operation.didSend(at: writeAt)
        let readAt = writeAt + 0.75
        XCTAssertNotNil(operation.nextCommand(at: readAt))
        operation.didSend(at: readAt)
        operation.receive(valueFrame(slot: 2, raw: 2_150, metadata: [0, 0]), at: readAt + 2.875)
        operation.receive(valueFrame(slot: 2, raw: 2_150), at: readAt + 3)
        assertUncertainFinished(operation)
        XCTAssertTrue(operation.failure?.contains("应答等待") == true)
        XCTAssertNil(operation.nextCommand(at: readAt + 4))
    }

    func testSecondWriteReadbackMustMatchEvenWhenTheFirstMatched() {
        var operation = saveOperation()
        let writeAt = prepareWrite(&operation)
        XCTAssertNotNil(operation.nextCommand(at: writeAt))
        operation.didSend(at: writeAt)
        let firstReadAt = writeAt + 0.75
        XCTAssertNotNil(operation.nextCommand(at: firstReadAt))
        operation.didSend(at: firstReadAt)
        operation.receive(valueFrame(slot: 2, raw: 2_150), at: firstReadAt + 0.125)
        let secondReadAt = firstReadAt + 0.875
        XCTAssertNotNil(operation.nextCommand(at: secondReadAt))
        operation.didSend(at: secondReadAt)
        operation.receive(valueFrame(slot: 2, raw: 1_000), at: secondReadAt + 0.125)
        assertUncertainFinished(operation)
        XCTAssertNil(operation.nextCommand(at: secondReadAt + 1))
    }

    func testCalibrationChangeBeforeOrAfterWriteCannotSucceed() {
        var before = saveOperation()
        XCTAssertNotNil(before.nextCommand(at: 0.75))
        before.didSend(at: 0.75)
        before.receive(baseFrame(cents: 6_300), at: 0.875)
        XCTAssertTrue(before.isFinished)
        XCTAssertFalse(before.writeSent)
        XCTAssertFalse(before.outcomeUncertain)

        var after = saveOperation()
        let writeAt = prepareWrite(&after)
        XCTAssertNotNil(after.nextCommand(at: writeAt))
        after.didSend(at: writeAt)
        var now = writeAt + 0.75
        for pass in 0...1 {
            XCTAssertNotNil(after.nextCommand(at: now))
            after.didSend(at: now)
            after.receive(valueFrame(slot: 2, raw: 2_150), at: now + 0.125)
            now += 0.125 + (pass == 0 ? 0.75 : 0.25)
        }
        XCTAssertEqual(after.nextCommand(at: now), DPI.readBase)
        after.didSend(at: now)
        after.receive(baseFrame(cents: 6_401), at: now + 0.125)
        assertUncertainFinished(after)
    }

    func testCalibrationIsRecheckedAfterThePreviousSlotAndBeforeAnySave() {
        var operation = saveOperation()
        let previousAt = begin(&operation)
        XCTAssertEqual(operation.nextCommand(at: previousAt), ControllerMemoryProtocol.read(slot: 2))
        operation.didSend(at: previousAt)
        // During the slot request this is not an eligible slot reply. The
        // mandatory next calibration query must still detect the change.
        operation.receive(baseFrame(cents: 6_300), at: previousAt + 0.125)
        XCTAssertNil(operation.replies[2])
        operation.receive(emptyFrame(slot: 2), at: previousAt + 0.25)
        let baseAt = previousAt + 0.5
        XCTAssertEqual(operation.nextCommand(at: baseAt), DPI.readBase)
        operation.didSend(at: baseAt)
        operation.receive(baseFrame(cents: 6_300), at: baseAt + 0.125)
        XCTAssertTrue(operation.isFinished)
        XCTAssertTrue(operation.failure?.contains("高度基准") == true)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertFalse(operation.trace.contains { $0.contains("OFFERED save-once:") })
        XCTAssertFalse(operation.trace.contains { $0.contains("TX save-once:") })
        XCTAssertNil(operation.nextCommand(at: baseAt + 1))
    }

    func testAmbiguousCalibrationDuringPreSaveDelayPreventsTheWrite() {
        var operation = saveOperation()
        let writeAt = prepareWrite(&operation)
        XCTAssertFalse(operation.acceptsEmptySlotOneReply)
        operation.receive(emptyFrame(slot: 1), at: writeAt - 0.125)
        XCTAssertTrue(operation.isFinished)
        XCTAssertNotNil(operation.failure)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertNil(operation.nextCommand(at: writeAt))
        XCTAssertFalse(operation.trace.contains { $0.contains("TX save-once:") })
    }

    func testAmbiguousCalibrationAfterWriteOfferPreventsAnyFurtherCommand() {
        var operation = saveOperation()
        let writeAt = prepareWrite(&operation)
        XCTAssertNotNil(operation.nextCommand(at: writeAt))
        XCTAssertFalse(operation.acceptsEmptySlotOneReply)
        operation.receive(emptyFrame(slot: 1), at: writeAt + 0.125)
        XCTAssertTrue(operation.isFinished)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.outcomeUncertain)
        XCTAssertNil(operation.nextCommand(at: writeAt + 1))
    }

    func testAmbiguousCalibrationDuringFinalQuietDrainMakesWriteUncertain() {
        var operation = saveOperation()
        let writeAt = prepareWrite(&operation)
        XCTAssertNotNil(operation.nextCommand(at: writeAt))
        operation.didSend(at: writeAt)
        var now = writeAt + 0.75
        for pass in 0...1 {
            XCTAssertNotNil(operation.nextCommand(at: now))
            operation.didSend(at: now)
            operation.receive(valueFrame(slot: 2, raw: 2_150), at: now + 0.125)
            now += 0.125 + (pass == 0 ? 0.75 : 0.25)
        }
        XCTAssertEqual(operation.nextCommand(at: now), DPI.readBase)
        operation.didSend(at: now)
        operation.receive(baseFrame(), at: now + 0.125)
        XCTAssertFalse(operation.isFinished)
        XCTAssertFalse(operation.acceptsEmptySlotOneReply)
        operation.receive(emptyFrame(slot: 1), at: now + 0.25)
        assertUncertainFinished(operation)
        XCTAssertNil(operation.nextCommand(at: now + 1))
    }

    func testEmptySlotOneIsAcceptedOnlyWhileItsOwnReadIsPending() {
        var operation = ControllerMemoryOperation(kind: .readAll, expectedBase: 64, now: 0)
        let firstAt = begin(&operation)
        XCTAssertFalse(operation.acceptsEmptySlotOneReply)
        operation.didSend(at: firstAt)
        operation.receive(slotFrame(0), at: firstAt + 0.125)
        let secondAt = firstAt + 0.375
        XCTAssertEqual(operation.nextCommand(at: secondAt), ControllerMemoryProtocol.read(slot: 1))
        XCTAssertFalse(operation.acceptsEmptySlotOneReply)
        operation.didSend(at: secondAt)
        XCTAssertTrue(operation.acceptsEmptySlotOneReply)
        operation.receive(emptyFrame(slot: 1), at: secondAt + 0.125)
        XCTAssertEqual(operation.replies[1]?.state, .empty)
        XCTAssertFalse(operation.acceptsEmptySlotOneReply)
        XCTAssertFalse(operation.isFinished)
        XCTAssertEqual(operation.nextCommand(at: secondAt + 0.375), ControllerMemoryProtocol.read(slot: 2))
    }

    func testCancelBeforeWriteIsCertainAndAfterWriteIsUncertain() {
        var before = saveOperation()
        before.cancel(reason: "窗口关闭", at: 0.25)
        XCTAssertTrue(before.isFinished)
        XCTAssertFalse(before.writeSent)
        XCTAssertFalse(before.outcomeUncertain)
        XCTAssertNil(before.nextCommand(at: 100))

        var after = saveOperation()
        let writeAt = prepareWrite(&after)
        XCTAssertNotNil(after.nextCommand(at: writeAt))
        after.didSend(at: writeAt)
        after.cancel(reason: "设备会话改变", at: writeAt + 0.125)
        assertUncertainFinished(after)
        after.receive(valueFrame(slot: 2, raw: 2_150), at: writeAt + 1)
        XCTAssertNil(after.nextCommand(at: writeAt + 2))
    }

    func testConstructorRejectsInvalidOrUnconfirmedSaveArguments() {
        let invalidKinds: [ControllerMemoryOperation.Kind] = [
            .save(slot: -1, raw: 1, expectedPrevious: .empty),
            .save(slot: 4, raw: 1, expectedPrevious: .empty),
            .save(slot: 0, raw: -1, expectedPrevious: .empty),
            .save(slot: 0, raw: 6_501, expectedPrevious: .empty),
            .save(slot: 0, raw: 1, expectedPrevious: .unknown),
            .save(slot: 0, raw: 1, expectedPrevious: .candidate(raw: 2, metadata: [1, 0])),
            .save(slot: 0, raw: 1, expectedPrevious: .candidate(raw: 6_501, metadata: [1, 1]))
        ]
        for kind in invalidKinds {
            var operation = ControllerMemoryOperation(kind: kind, expectedBase: 64, now: 0)
            XCTAssertTrue(operation.isFinished)
            XCTAssertNotNil(operation.failure)
            XCTAssertFalse(operation.writeSent)
            XCTAssertNil(operation.nextCommand(at: 1))
        }
        for raw in [0, 6_500] {
            let operation = ControllerMemoryOperation(kind: .save(slot: 3, raw: raw,
                expectedPrevious: .candidate(raw: 0, metadata: [1, 1])), expectedBase: 63.05, now: 0)
            XCTAssertFalse(operation.isFinished)
        }
    }

    func testInvalidClockOrRollbackFailsWithWriteUncertaintyPreserved() {
        var read = ControllerMemoryOperation(kind: .readAll, expectedBase: 64, now: 0)
        XCTAssertNotNil(read.nextCommand(at: 0.75))
        read.poll(at: 0.5)
        XCTAssertTrue(read.isFinished)
        XCTAssertNotNil(read.failure)
        XCTAssertFalse(read.outcomeUncertain)

        var write = saveOperation()
        let now = prepareWrite(&write)
        XCTAssertNotNil(write.nextCommand(at: now))
        write.didSend(at: now)
        write.poll(at: .nan)
        assertUncertainFinished(write)
    }

    private func begin(_ operation: inout ControllerMemoryOperation) -> TimeInterval {
        XCTAssertEqual(operation.nextCommand(at: 0.75), DPI.readBase)
        operation.didSend(at: 0.75)
        operation.receive(baseFrame(), at: 0.875)
        return 1.125
    }

    private func saveOperation(previous: ControllerMemoryProtocol.SlotState = .empty) -> ControllerMemoryOperation {
        ControllerMemoryOperation(kind: .save(slot: 2, raw: 2_150, expectedPrevious: previous), expectedBase: 64, now: 0)
    }

    private func prepareWrite(_ operation: inout ControllerMemoryOperation) -> TimeInterval {
        let now = begin(&operation)
        XCTAssertEqual(operation.nextCommand(at: now), ControllerMemoryProtocol.read(slot: 2))
        operation.didSend(at: now)
        operation.receive(emptyFrame(slot: 2), at: now + 0.125)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.isFinished)
        let baseAt = now + 0.375
        XCTAssertEqual(operation.nextCommand(at: baseAt), DPI.readBase)
        operation.didSend(at: baseAt)
        operation.receive(baseFrame(), at: baseAt + 0.125)
        XCTAssertFalse(operation.writeSent)
        XCTAssertFalse(operation.isFinished)
        return baseAt + 0.375
    }

    private func verifyFinalBaseAndDrain(_ operation: inout ControllerMemoryOperation, at now: TimeInterval) {
        XCTAssertEqual(operation.nextCommand(at: now), DPI.readBase)
        operation.didSend(at: now)
        operation.receive(baseFrame(), at: now + 0.125)
        XCTAssertFalse(operation.isFinished)
        operation.receive(Data([0xff]), at: now + 0.25)
        XCTAssertNil(operation.nextCommand(at: now + 0.75))
        XCTAssertFalse(operation.isFinished)
        operation.poll(at: now + 0.875)
        XCTAssertTrue(operation.isFinished)
    }

    private func assertUncertainFinished(_ operation: ControllerMemoryOperation,
                                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(operation.isFinished, file: file, line: line)
        XCTAssertNotNil(operation.failure, file: file, line: line)
        XCTAssertTrue(operation.writeSent, file: file, line: line)
        XCTAssertTrue(operation.outcomeUncertain, file: file, line: line)
    }

    private func baseFrame(cents: Int = 6_400) -> Data {
        Data([1, 3, 1, UInt8(cents & 255), UInt8(cents >> 8)])
    }

    private func emptyFrame(slot: Int) -> Data { Data([1, 3, UInt8(slot), 1, 0]) }

    private func valueFrame(slot: Int, raw: Int, metadata: [UInt8] = [1, 1]) -> Data {
        Data([1, 5, UInt8(slot)] + metadata + [UInt8(raw & 255), UInt8(raw >> 8)])
    }

    private func slotFrame(_ slot: Int) -> Data {
        slot == 1 ? emptyFrame(slot: slot) : valueFrame(slot: slot, raw: slot * 1_000)
    }
}
