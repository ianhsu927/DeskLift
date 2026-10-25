import Foundation

// Read/save/delete commands and the empty-slot fixture are documented at revision
// b61acfeeb9d716a631aee2ed3acebdfed6f50f15 of ha-linak-dpi1c-control.
enum ControllerMemoryProtocol {
    enum SlotState: Equatable, Sendable {
        // Preserve metadata for diagnostics. Only the observed [1, 1] format
        // is exposed through confirmedRaw; no reply authorizes movement.
        case candidate(raw: Int, metadata: [UInt8])
        case empty
        case unknown
    }

    struct Reply: Equatable, Sendable {
        let slot: Int
        let state: SlotState
        let rawFrame: Data

        var hex: String { rawFrame.map { String(format: "%02X", $0) }.joined(separator: " ") }

        var confirmedRaw: Int? {
            guard case .candidate(let raw, let metadata) = state,
                  metadata == [0x01, 0x01], DPI.target(raw) != nil else { return nil }
            return raw
        }

        var isRecognizedStorageReply: Bool {
            if case .empty = state { return true }
            return confirmedRaw != nil
        }
    }

    // Construct this only for a read that was actually sent. The caller must
    // serialize configuration reads; frame bytes alone cannot identify the
    // slot-1 empty reply versus a 0.01 cm calibration reply.
    struct ReadContext: Equatable, Sendable {
        let slot: Int

        init?(slot: Int) {
            guard (0...3).contains(slot) else { return nil }
            self.slot = slot
        }

        var command: Data { Data([0x7f, 0x99, 0x00, UInt8(slot)]) }

        func parse(_ data: Data) -> Reply {
            ControllerMemoryProtocol.parse(data, pending: self)
        }
    }

    static func read(slot: Int) -> Data? { ReadContext(slot: slot)?.command }

    static func isReadCommand(_ data: Data) -> Bool {
        let bytes = Array(data)
        return bytes.count == 4 && bytes[0] == 0x7f && bytes[1] == 0x99
            && bytes[2] == 0x00 && bytes[3] <= 3
    }

    static func save(slot: Int, raw: Int) -> Data? {
        guard (0...3).contains(slot), let position = DPI.target(raw) else { return nil }
        var command = Data([0x7f, 0x99, 0x80, UInt8(slot), 0x01, 0x01])
        command.append(position)
        return command
    }

    static func isSaveCommand(_ data: Data) -> Bool {
        let bytes = Array(data)
        guard bytes.count == 8, bytes[0] == 0x7f, bytes[1] == 0x99,
              bytes[2] == 0x80, bytes[3] <= 3,
              bytes[4] == 0x01, bytes[5] == 0x01 else { return false }
        let raw = Int(bytes[6]) | Int(bytes[7]) << 8
        return DPI.target(raw) != nil
    }

    static func delete(slot: Int) -> Data? {
        guard (0...3).contains(slot) else { return nil }
        return Data([0x7f, 0x99, 0x80, UInt8(slot), 0x01, 0x00])
    }

    static func isDeleteCommand(_ data: Data) -> Bool {
        let bytes = Array(data)
        return bytes.count == 6 && bytes[0] == 0x7f && bytes[1] == 0x99
            && bytes[2] == 0x80 && bytes[3] <= 3
            && bytes[4] == 0x01 && bytes[5] == 0x00
    }

    static func parse(_ data: Data, pending context: ReadContext) -> Reply {
        let bytes = Array(data)
        let state: SlotState
        if bytes.count == 5, bytes[0] == 0x01, bytes[1] == 0x03,
           bytes[2] == UInt8(context.slot), bytes[3] == 0x01, bytes[4] == 0x00 {
            state = .empty
        } else if bytes.count == 7, bytes[0] == 0x01, bytes[1] == 0x05,
                  bytes[2] == UInt8(context.slot) {
            let raw = Int(bytes[5]) | Int(bytes[6]) << 8
            if DPI.target(raw) != nil {
                state = .candidate(raw: raw, metadata: Array(bytes[3...4]))
            } else {
                state = .unknown
            }
        } else {
            // The fixed source has no positive fixture proving the flags of
            // value replies. Keep other frames intact for diagnostics.
            state = .unknown
        }
        return Reply(slot: context.slot, state: state, rawFrame: data)
    }
}
