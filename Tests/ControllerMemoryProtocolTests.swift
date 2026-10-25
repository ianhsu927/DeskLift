import Foundation
import XCTest

final class ControllerMemoryProtocolTests: XCTestCase {
    func testReadCommandsAreLimitedToFourReadOnlySlots() throws {
        for slot in 0...3 {
            let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: slot))
            let expected = Data([0x7f, 0x99, 0x00, UInt8(slot)])
            XCTAssertEqual(context.command, expected)
            XCTAssertEqual(ControllerMemoryProtocol.read(slot: slot), expected)
            XCTAssertTrue(ControllerMemoryProtocol.isReadCommand(expected))
        }
        for slot in [-1, 4, Int.min, Int.max] {
            XCTAssertNil(ControllerMemoryProtocol.ReadContext(slot: slot))
            XCTAssertNil(ControllerMemoryProtocol.read(slot: slot))
        }
    }

    func testWhitelistRejectsWritesOtherCommandsAndMalformedReads() {
        let commands: [[UInt8]] = [
            [], [0x7f], [0x7f, 0x99, 0x00], [0x7f, 0x99, 0x00, 4],
            [0x7f, 0x99, 0x00, 0, 0], [0x7f, 0x99, 0x80, 0, 1, 0],
            [0x7f, 0x99, 0x80, 0, 1, 1, 0, 0], [0x7f, 0x81, 0],
            [0xff, 0x00], [0x7e, 0x99, 0x00, 0]
        ]
        for bytes in commands {
            XCTAssertFalse(ControllerMemoryProtocol.isReadCommand(Data(bytes)))
        }
    }

    func testSaveCommandsUseExactFormatAndWireRange() throws {
        let positions: [(raw: Int, littleEndian: [UInt8])] = [
            (0, [0x00, 0x00]), (3, [0x03, 0x00]),
            (4_349, [0xfd, 0x10]), (6_500, [0x64, 0x19])
        ]
        for slot in 0...3 {
            for position in positions {
                let command = try XCTUnwrap(ControllerMemoryProtocol.save(slot: slot, raw: position.raw))
                let expected = Data([0x7f, 0x99, 0x80, UInt8(slot), 0x01, 0x01] + position.littleEndian)
                XCTAssertEqual(command, expected)
                XCTAssertTrue(ControllerMemoryProtocol.isSaveCommand(command))
                XCTAssertFalse(ControllerMemoryProtocol.isReadCommand(command))
            }
        }
    }

    func testSaveRejectsInvalidSlotOrRawInsteadOfClamping() {
        for slot in [-1, 4, Int.min, Int.max] {
            XCTAssertNil(ControllerMemoryProtocol.save(slot: slot, raw: 0))
            XCTAssertNil(ControllerMemoryProtocol.save(slot: slot, raw: DPI.maxRaw))
        }
        for slot in 0...3 {
            for raw in [-1, DPI.maxRaw + 1, Int.min, Int.max] {
                XCTAssertNil(ControllerMemoryProtocol.save(slot: slot, raw: raw))
            }
        }
    }

    func testSaveWhitelistRejectsMalformedFramesAndOtherSubcommands() {
        let valid = Data([0x7f, 0x99, 0x80, 0x00, 0x01, 0x01, 0x03, 0x00])
        for length in 0..<valid.count {
            XCTAssertFalse(ControllerMemoryProtocol.isSaveCommand(Data(valid.prefix(length))))
        }
        let rejected: [[UInt8]] = [
            [0x7f, 0x99, 0x80, 0, 1, 1, 3, 0, 0],
            [0x7e, 0x99, 0x80, 0, 1, 1, 3, 0],
            [0x7f, 0x98, 0x80, 0, 1, 1, 3, 0],
            [0x7f, 0x99, 0x00, 0, 1, 1, 3, 0],
            [0x7f, 0x99, 0x81, 0, 1, 1, 3, 0],
            [0x7f, 0x99, 0x80, 4, 1, 1, 3, 0],
            [0x7f, 0x99, 0x80, 0, 0, 1, 3, 0],
            [0x7f, 0x99, 0x80, 0, 1, 0, 3, 0],
            [0x7f, 0x99, 0x80, 0, 1, 2, 3, 0],
            [0x7f, 0x99, 0x80, 0, 1, 1, 0x65, 0x19],
            [0x7f, 0x99, 0x80, 0, 1, 1, 0xff, 0xff],
            [0x7f, 0x99, 0x80, 0, 1, 0], // Delete is never a save.
            [0x7f, 0x99, 0x00, 0], [0x7f, 0x81, 0], [0xff, 0x00], [0x01, 0x80]
        ]
        for bytes in rejected {
            XCTAssertFalse(ControllerMemoryProtocol.isSaveCommand(Data(bytes)))
        }
    }

    func testConfirmedRawRequiresRecognizedMetadata() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 0))
        for raw in [0, 4_349, DPI.maxRaw] {
            let frame = Data([1, 5, 0, 1, 1, UInt8(raw & 255), UInt8(raw >> 8)])
            let reply = context.parse(frame)
            XCTAssertEqual(reply.confirmedRaw, raw)
            XCTAssertTrue(reply.isRecognizedStorageReply)
        }
        let metadataValues: [[UInt8]] = [[0, 0], [1, 0], [0, 1], [1, 2], [0xff, 0xff]]
        for metadata in metadataValues {
            let frame = Data([1, 5, 0] + metadata + [3, 0])
            let reply = context.parse(frame)
            XCTAssertEqual(reply.state, .candidate(raw: 3, metadata: metadata))
            XCTAssertNil(reply.confirmedRaw)
            XCTAssertFalse(reply.isRecognizedStorageReply)
            XCTAssertEqual(reply.rawFrame, frame)
        }
    }

    func testEmptyAndUnknownStorageReplyRecognition() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 3))
        let empty = context.parse(Data([1, 3, 3, 1, 0]))
        XCTAssertNil(empty.confirmedRaw)
        XCTAssertTrue(empty.isRecognizedStorageReply)

        for frame in [Data(), Data([1, 3, 2, 1, 0]), Data([1, 5, 3, 1, 1, 0x65, 0x19])] {
            let reply = context.parse(frame)
            XCTAssertEqual(reply.state, .unknown)
            XCTAssertNil(reply.confirmedRaw)
            XCTAssertFalse(reply.isRecognizedStorageReply)
        }
    }

    func testFixedSourceEmptySlotFixture() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 2))
        let frame = Data([0x01, 0x03, 0x02, 0x01, 0x00])
        let reply = context.parse(frame)
        XCTAssertEqual(reply.slot, 2)
        XCTAssertEqual(reply.state, .empty)
        XCTAssertEqual(reply.rawFrame, frame)
        XCTAssertEqual(reply.hex, "01 03 02 01 00")
    }

    func testSlotOneAmbiguityRequiresTheCallersPendingQueryContext() throws {
        let frame = Data([0x01, 0x03, 0x01, 0x01, 0x00])
        XCTAssertEqual(DPI.base(frame), 0.01)

        let slotOne = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 1))
        XCTAssertEqual(slotOne.parse(frame).state, .empty)

        let slotTwo = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 2))
        XCTAssertEqual(slotTwo.parse(frame).state, .unknown)
    }

    func testOrdinaryCalibrationIsNotMistakenForAnEmptySlot() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 1))
        let frame = Data([0x01, 0x03, 0x01, 0x00, 0x19])
        XCTAssertEqual(DPI.base(frame), 64)
        XCTAssertEqual(context.parse(frame).state, .unknown)
    }

    func testCandidatesPreserveUnverifiedMetadataIncludingZeroAndTravelLimits() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 0))
        let metadataValues: [[UInt8]] = [[0, 0], [1, 1], [1, 0], [0xff, 0xff]]
        for metadata in metadataValues {
            for raw in [0, 1, DPI.maxRaw] {
                let frame = Data([1, 5, 0] + metadata + [UInt8(raw & 255), UInt8(raw >> 8)])
                let reply = context.parse(frame)
                XCTAssertEqual(reply.state, .candidate(raw: raw, metadata: metadata))
                XCTAssertEqual(reply.rawFrame, frame)
            }
        }
    }

    func testOutOfRangeCandidatesRemainUnknown() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 0))
        for raw in [DPI.maxRaw + 1, 0xffff] {
            let frame = Data([1, 5, 0, 1, 1, UInt8(raw & 255), UInt8(raw >> 8)])
            XCTAssertEqual(context.parse(frame).state, .unknown)
        }
    }

    func testCandidateRequiresExactLengthHeaderAndPendingSlot() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 2))
        let valid = Data([1, 5, 2, 1, 1, 0xe8, 0x03])
        XCTAssertEqual(context.parse(valid).state, .candidate(raw: 1_000, metadata: [1, 1]))
        for count in 0..<valid.count {
            XCTAssertEqual(context.parse(Data(valid.prefix(count))).state, .unknown)
        }
        let invalidFrames: [[UInt8]] = [
            [1, 5, 2, 1, 1, 0xe8, 0x03, 0],
            [0, 5, 2, 1, 1, 0xe8, 0x03],
            [1, 4, 2, 1, 1, 0xe8, 0x03],
            [1, 5, 1, 1, 1, 0xe8, 0x03],
            [1, 5, 4, 1, 1, 0xe8, 0x03]
        ]
        for bytes in invalidFrames {
            XCTAssertEqual(context.parse(Data(bytes)).state, .unknown)
        }
    }

    func testMalformedEmptyRepliesAndWrongSlotsRemainUnknown() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 2))
        let frames: [[UInt8]] = [
            [], [1], [1, 3], [1, 3, 2], [1, 3, 2, 1],
            [1, 3, 2, 1, 0, 0], [0, 3, 2, 1, 0], [1, 4, 2, 1, 0],
            [1, 3, 1, 1, 0], [1, 3, 4, 1, 0], [1, 3, 2, 0, 0], [1, 3, 2, 1, 1]
        ]
        for bytes in frames {
            XCTAssertEqual(context.parse(Data(bytes)).state, .unknown)
        }
    }

    func testUnknownReplyRetainsEveryByteForDiagnostics() throws {
        let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: 3))
        let frame = Data([0xff, 0x00, 0xab, 0x07])
        let reply = context.parse(frame)
        XCTAssertEqual(reply.slot, 3)
        XCTAssertEqual(reply.state, .unknown)
        XCTAssertEqual(reply.hex, "FF 00 AB 07")
        XCTAssertEqual(context.parse(Data()).hex, "")
    }

    func testCapturedDPI1CRepliesMatchAcrossBothReadOnlyRounds() throws {
        // Captured in 控制器记忆原始日志-20261025-133423.txt. Metadata remains
        // diagnostic; this observation does not generalize its semantics.
        let baseBefore = Data([0x01, 0x03, 0x01, 0x38, 0x18])
        let baseAfter = Data([0x01, 0x03, 0x01, 0x38, 0x18])
        XCTAssertEqual(DPI.base(baseBefore), 62)
        XCTAssertEqual(DPI.base(baseAfter), 62)

        let rounds: [[Data]] = [
            [
                Data([0x01, 0x05, 0x00, 0x01, 0x01, 0x03, 0x00]),
                Data([0x01, 0x05, 0x01, 0x01, 0x01, 0xfd, 0x10]),
                Data([0x01, 0x05, 0x02, 0x01, 0x01, 0x75, 0x02]),
                Data([0x01, 0x03, 0x03, 0x01, 0x00])
            ],
            [
                Data([0x01, 0x05, 0x00, 0x01, 0x01, 0x03, 0x00]),
                Data([0x01, 0x05, 0x01, 0x01, 0x01, 0xfd, 0x10]),
                Data([0x01, 0x05, 0x02, 0x01, 0x01, 0x75, 0x02]),
                Data([0x01, 0x03, 0x03, 0x01, 0x00])
            ]
        ]
        let expected: [ControllerMemoryProtocol.SlotState] = [
            .candidate(raw: 3, metadata: [1, 1]),
            .candidate(raw: 4_349, metadata: [1, 1]),
            .candidate(raw: 629, metadata: [1, 1]),
            .empty
        ]
        let confirmedPositions: [Int?] = [3, 4_349, 629, nil]
        var decodedRounds: [[ControllerMemoryProtocol.Reply]] = []
        for round in rounds {
            var replies: [ControllerMemoryProtocol.Reply] = []
            for (slot, frame) in round.enumerated() {
                let context = try XCTUnwrap(ControllerMemoryProtocol.ReadContext(slot: slot))
                let reply = context.parse(frame)
                XCTAssertEqual(reply.state, expected[slot])
                XCTAssertEqual(reply.confirmedRaw, confirmedPositions[slot])
                XCTAssertTrue(reply.isRecognizedStorageReply)
                XCTAssertEqual(reply.rawFrame, frame)
                replies.append(reply)
            }
            decodedRounds.append(replies)
        }
        XCTAssertEqual(decodedRounds[0], decodedRounds[1])
    }
}
