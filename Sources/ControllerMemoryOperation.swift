import Foundation

// The host owns connection, calibration and physical-position invariants. It
// must consume nextCommand immediately and report each actual send synchronously.
// Slot frames contain no transaction ID; quiet periods cannot prove that an
// identically shaped historical reply belongs to the current request.
struct ControllerMemoryOperation {
    enum Kind {
        case readAll
        case save(slot: Int, raw: Int, expectedPrevious: ControllerMemoryProtocol.SlotState)
    }

    private enum Request {
        case baseBefore, baseBeforeWrite, baseAfter
        case readAll(round: Int, slot: Int)
        case previous(slot: Int)
        case save
        case verify(slot: Int, pass: Int)

        var label: String {
            switch self {
            case .baseBefore: return "base-before"
            case .baseBeforeWrite: return "base-before-write"
            case .baseAfter: return "base-after"
            case .readAll(let round, let slot): return "round-\(round + 1) slot-\(slot)"
            case .previous(let slot): return "previous slot-\(slot)"
            case .save: return "save-once"
            case .verify(let slot, let pass): return "verify-\(pass + 1) slot-\(slot)"
            }
        }

        var slot: Int? {
            switch self {
            case .readAll(_, let slot), .previous(let slot), .verify(let slot, _): return slot
            default: return nil
            }
        }

        var isSave: Bool {
            if case .save = self { return true }
            return false
        }
    }

    private enum Phase {
        case queued(Request, notBefore: TimeInterval, deadline: TimeInterval)
        case writeOffered(deadline: TimeInterval)
        case awaiting(Request, deadline: TimeInterval)
        case draining(until: TimeInterval)
        case finished
    }

    private let kind: Kind
    private let expectedBase: Double
    private var phase: Phase = .finished
    private var lastObservedAt: TimeInterval?
    private var firstRound: [ControllerMemoryProtocol.Reply?] = Array(repeating: nil, count: 4)

    private(set) var isFinished = false
    private(set) var failure: String?
    private(set) var writeSent = false
    private(set) var outcomeUncertain = false
    // Latest recognized observation; the host must apply it only after success.
    private(set) var replies: [ControllerMemoryProtocol.Reply?] = Array(repeating: nil, count: 4)
    private(set) var trace: [String] = []

    // 01 03 01 01 00 can also mean a 0.01 cm calibration. Only an
    // actually sent read of slot 1 is allowed to interpret it as an empty slot.
    var acceptsEmptySlotOneReply: Bool {
        guard !isFinished, case .awaiting(let request, _) = phase else { return false }
        return request.slot == 1
    }

    init(kind: Kind, expectedBase: Double, now: TimeInterval) {
        self.kind = kind
        self.expectedBase = expectedBase
        guard expectedBase.isFinite, (0...250).contains(expectedBase), now.isFinite, now >= 0 else {
            fail("内部记忆操作的基准或时钟无效", at: now)
            return
        }
        if case .save(let slot, let raw, let previous) = kind {
            let previousReply = ControllerMemoryProtocol.Reply(slot: slot, state: previous, rawFrame: Data())
            guard ControllerMemoryProtocol.save(slot: slot, raw: raw) != nil,
                  previousReply.isRecognizedStorageReply else {
                fail("写入槽位、目标或确认前的档位值无效", at: now)
                return
            }
        }
        lastObservedAt = now
        enqueue(.baseBefore, after: 0.75, at: now)
    }

    mutating func nextCommand(at now: TimeInterval) -> Data? {
        poll(at: now)
        guard !isFinished,
              case .queued(let request, let notBefore, let deadline) = phase,
              now >= notBefore,
              let data = command(for: request) else { return nil }
        if request.isSave {
            // An offered persistent write is never returned a second time,
            // even when a caller forgets to report a failed send.
            phase = .writeOffered(deadline: deadline)
            record("OFFERED save-once: \(Self.hex(data))", at: now)
        }
        return data
    }

    mutating func didSend(at now: TimeInterval) {
        // didSend asserts that the write really left the caller. Mark this
        // before checking its lease so an overdue send also fails uncertain.
        if !isFinished {
            switch phase {
            case .writeOffered: writeSent = true
            case .queued(let request, _, _) where request.isSave: writeSent = true
            default: break
            }
        }
        poll(at: now)
        guard !isFinished else { return }
        switch phase {
        case .writeOffered:
            guard let data = command(for: .save), case .save(let slot, _, _) = kind else {
                fail("拒绝了无效的内部记忆写入", at: now)
                return
            }
            record("TX save-once: \(Self.hex(data))", at: now)
            enqueue(.verify(slot: slot, pass: 0), after: 0.75, at: now)
        case .queued(let request, let notBefore, _):
            guard let data = command(for: request) else {
                fail("拒绝了命令白名单以外的操作", at: now)
                return
            }
            record("TX \(request.label): \(Self.hex(data))", at: now)
            guard !request.isSave, now >= notBefore else {
                fail("命令未按允许的发送时序执行", at: now)
                return
            }
            let deadline = now + 3
            guard deadline.isFinite, deadline > now else {
                fail("无法建立应答期限", at: now)
                return
            }
            phase = .awaiting(request, deadline: deadline)
        case .awaiting(let request, _):
            record("IGNORED duplicate didSend \(request.label)", at: now)
        case .draining, .finished:
            break
        }
    }

    mutating func didFailToSend(at now: TimeInterval) {
        poll(at: now)
        guard !isFinished else { return }
        switch phase {
        case .writeOffered:
            fail("写入请求未发送，请重新确认后再试；不会自动重试", at: now)
        case .queued(let request, _, _) where request.isSave:
            fail("写入请求未发送，请重新确认后再试；不会自动重试", at: now)
        case .queued(let request, _, _):
            record("NOT-SENT \(request.label); original send deadline retained", at: now)
        default:
            break
        }
    }

    mutating func receive(_ data: Data, at now: TimeInterval) {
        poll(at: now)
        guard !isFinished else {
            record("RX ignored after finish: \(Self.hex(data))", at: now)
            return
        }
        if data == Data([1, 3, 1, 1, 0]), !acceptsEmptySlotOneReply {
            record("RX ambiguous calibration/slot-1: \(Self.hex(data))", at: now)
            fail("配置回复无法区分空档位与高度基准，操作不能确认", at: now)
            return
        }
        guard case .awaiting(let request, _) = phase else {
            record("RX ignored without a pending read: \(Self.hex(data))", at: now)
            return
        }
        record("RX \(request.label): \(Self.hex(data))", at: now)
        switch request {
        case .baseBefore, .baseBeforeWrite, .baseAfter:
            guard let base = DPI.base(data) else { return }
            guard base == expectedBase else {
                fail("高度基准已改变，操作不能确认", at: now)
                return
            }
            if case .baseAfter = request {
                let until = now + 0.75
                guard until.isFinite, until > now else {
                    fail("无法建立结束隔离间隔", at: now)
                    return
                }
                phase = .draining(until: until)
                record("DRAIN until \(until)", at: now)
            } else if case .baseBeforeWrite = request {
                enqueue(.save, after: 0.25, at: now)
            } else {
                switch kind {
                case .readAll: enqueue(.readAll(round: 0, slot: 0), after: 0.25, at: now)
                case .save(let slot, _, _): enqueue(.previous(slot: slot), after: 0.25, at: now)
                }
            }
        case .readAll(let round, let slot):
            guard let reply = recognizedReply(data, slot: slot) else { return }
            replies[slot] = reply
            if round == 0 {
                firstRound[slot] = reply
            } else {
                guard firstRound[slot]?.state == reply.state else {
                    fail("槽位 \(slot) 两轮读取不一致", at: now)
                    return
                }
            }
            if slot < 3 {
                enqueue(.readAll(round: round, slot: slot + 1), after: 0.25, at: now)
            } else if round == 0 {
                enqueue(.readAll(round: 1, slot: 0), after: 0.75, at: now)
            } else {
                enqueue(.baseAfter, after: 0.25, at: now)
            }
        case .previous(let slot):
            guard let reply = recognizedReply(data, slot: slot) else { return }
            replies[slot] = reply
            guard case .save(_, _, let previous) = kind, reply.state == previous else {
                fail("确认后的原档位已改变，未执行写入", at: now)
                return
            }
            enqueue(.baseBeforeWrite, after: 0.25, at: now)
        case .verify(let slot, let pass):
            guard let reply = recognizedReply(data, slot: slot) else { return }
            replies[slot] = reply
            guard case .save(_, let raw, _) = kind, reply.confirmedRaw == raw else {
                fail("写后回读与目标不一致，结果不确定", at: now)
                return
            }
            if pass == 0 {
                enqueue(.verify(slot: slot, pass: 1), after: 0.75, at: now)
            } else {
                enqueue(.baseAfter, after: 0.25, at: now)
            }
        case .save:
            fail("写入不能作为待应答读取请求", at: now)
        }
    }

    mutating func poll(at now: TimeInterval) {
        guard !isFinished else { return }
        guard now.isFinite, now >= 0, lastObservedAt.map({ now >= $0 }) ?? true else {
            fail("内部记忆操作时钟无效或发生倒退", at: now)
            return
        }
        lastObservedAt = now
        switch phase {
        case .queued(let request, _, let deadline) where now >= deadline:
            fail("\(request.label) 发送等待超过 3 秒", at: now)
        case .writeOffered(let deadline) where now >= deadline:
            fail("写入发送结果未确认，不会重新发送", at: now)
        case .awaiting(let request, let deadline) where now >= deadline:
            fail("\(request.label) 应答等待超过 3 秒", at: now)
        case .draining(let until) where now >= until:
            isFinished = true
            phase = .finished
            record("COMPLETED verified replies and final quiet drain", at: now)
        default:
            break
        }
    }

    mutating func cancel(reason: String, at now: TimeInterval) {
        guard !isFinished else { return }
        fail("操作已取消：\(reason)", at: now)
    }

    private func recognizedReply(_ data: Data, slot: Int) -> ControllerMemoryProtocol.Reply? {
        guard let context = ControllerMemoryProtocol.ReadContext(slot: slot) else { return nil }
        let reply = context.parse(data)
        return reply.isRecognizedStorageReply ? reply : nil
    }

    private func command(for request: Request) -> Data? {
        let data: Data?
        if request.isSave {
            guard case .save(let slot, let raw, _) = kind else { return nil }
            data = ControllerMemoryProtocol.save(slot: slot, raw: raw)
        } else if let slot = request.slot {
            data = ControllerMemoryProtocol.read(slot: slot)
        } else {
            data = DPI.readBase
        }
        guard let data, data == DPI.readBase || ControllerMemoryProtocol.isReadCommand(data)
                || (request.isSave && ControllerMemoryProtocol.isSaveCommand(data)) else { return nil }
        return data
    }

    private mutating func enqueue(_ request: Request, after delay: TimeInterval, at now: TimeInterval) {
        let notBefore = now + delay
        let deadline = notBefore + 3
        guard notBefore.isFinite, notBefore > now, deadline.isFinite, deadline > notBefore,
              !request.isSave || !writeSent else {
            fail("无法建立下一条命令或禁止重复写入", at: now)
            return
        }
        phase = .queued(request, notBefore: notBefore, deadline: deadline)
        record("QUEUED \(request.label); not-before \(notBefore)", at: now)
    }

    private mutating func fail(_ reason: String, at now: TimeInterval) {
        guard !isFinished else { return }
        failure = reason
        outcomeUncertain = writeSent
        isFinished = true
        phase = .finished
        record("FAILED \(reason)" + (outcomeUncertain ? "; 写入结果不确定，不重试或回滚" : ""), at: now)
    }

    private mutating func record(_ message: String, at now: TimeInterval) {
        trace.append(String(format: "%.3f", now) + " " + message)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
