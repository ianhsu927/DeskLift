import Foundation

// A bounded, read-only diagnostic. No command is considered sent until didSend.
// Same-slot frames carry no transaction ID: a historical frame arriving during
// another read of that slot cannot be distinguished on bytes alone. The host
// must keep this session isolated from calibration and all movement commands.
struct ControllerMemoryReadSession {
    private enum Request {
        case baseBefore
        case slot(round: Int, index: Int)
        case baseAfter

        var label: String {
            switch self {
            case .baseBefore: return "base-before"
            case .slot(let round, let index): return "round-\(round + 1) slot-\(index)"
            case .baseAfter: return "base-after"
            }
        }

        var command: Data? {
            switch self {
            case .baseBefore, .baseAfter: return DPI.readBase
            case .slot(_, let index): return ControllerMemoryProtocol.read(slot: index)
            }
        }
    }

    private enum Phase {
        case queued(Request, notBefore: TimeInterval, deadline: TimeInterval)
        case awaiting(Request, deadline: TimeInterval)
        case finished
    }

    private let expectedBase: Double
    private var phase: Phase = .finished
    private var lastObservedAt: TimeInterval?

    private(set) var isFinished = false
    private(set) var failure: String?
    private(set) var replies: [[ControllerMemoryProtocol.Reply?]] = Array(
        repeating: Array(repeating: nil, count: 4), count: 2
    )
    private(set) var trace: [String] = []

    init(expectedBase: Double, now: TimeInterval) {
        self.expectedBase = expectedBase
        guard expectedBase.isFinite, (0...250).contains(expectedBase) else {
            fail("诊断开始时的高度基准无效", at: now)
            return
        }
        guard now.isFinite, now >= 0 else {
            fail("诊断时钟无效", at: now)
            return
        }
        lastObservedAt = now
        enqueue(.baseBefore, after: 0.75, at: now)
    }

    // Repeated calls return the same command under backpressure. They do not
    // create a reply context or extend either deadline.
    mutating func nextCommand(at now: TimeInterval) -> Data? {
        poll(at: now)
        guard !isFinished,
              case .queued(let request, let notBefore, _) = phase,
              now >= notBefore else { return nil }
        return allowedCommand(for: request, at: now)
    }

    mutating func didSend(at now: TimeInterval) {
        poll(at: now)
        guard !isFinished else { return }
        switch phase {
        case .queued(let request, let notBefore, _):
            guard let command = allowedCommand(for: request, at: now) else { return }
            record("TX \(request.label): \(Self.hex(command))", at: now)
            guard now >= notBefore else {
                fail("读取请求在等待间隔结束前发送", at: now)
                return
            }
            let deadline = now + 3
            guard deadline.isFinite, deadline > now else {
                fail("诊断时钟无法建立应答期限", at: now)
                return
            }
            phase = .awaiting(request, deadline: deadline)
        case .awaiting(let request, _):
            // A duplicate acknowledgement cannot renew the first send's lease.
            record("IGNORED duplicate didSend \(request.label)", at: now)
        case .finished:
            break
        }
    }

    mutating func receive(_ data: Data, at now: TimeInterval) {
        poll(at: now)
        guard !isFinished else {
            record("RX ignored after finish: \(Self.hex(data))", at: now)
            return
        }
        guard case .awaiting(let request, _) = phase else {
            record("RX ignored without a sent request: \(Self.hex(data))", at: now)
            return
        }
        record("RX \(request.label): \(Self.hex(data))", at: now)

        switch request {
        case .baseBefore, .baseAfter:
            guard let base = DPI.base(data) else {
                record("IGNORED unrecognized calibration reply", at: now)
                return
            }
            guard base == expectedBase else {
                fail("高度基准改变：预期 \(expectedBase) cm，收到 \(base) cm", at: now)
                return
            }
            switch request {
            case .baseBefore:
                enqueue(.slot(round: 0, index: 0), after: 0.25, at: now)
            case .baseAfter:
                isFinished = true
                phase = .finished
                record("COMPLETED two matching rounds and unchanged calibration", at: now)
            case .slot:
                break
            }
        case .slot(let round, let index):
            guard let context = ControllerMemoryProtocol.ReadContext(slot: index) else {
                fail("诊断包含无效槽位", at: now)
                return
            }
            let reply = context.parse(data)
            guard reply.state != .unknown else {
                record("IGNORED unknown or wrong-slot reply", at: now)
                return
            }
            replies[round][index] = reply
            if round == 1 {
                guard let first = replies[0][index], first.state == reply.state else {
                    fail("槽位 \(index) 两轮读取不一致（包含元数据）", at: now)
                    return
                }
            }
            if index < 3 {
                enqueue(.slot(round: round, index: index + 1), after: 0.25, at: now)
            } else if round == 0 {
                enqueue(.slot(round: 1, index: 0), after: 0.75, at: now)
            } else {
                enqueue(.baseAfter, after: 0.25, at: now)
            }
        }
    }

    mutating func poll(at now: TimeInterval) {
        guard !isFinished else { return }
        guard now.isFinite, now >= 0,
              lastObservedAt.map({ now >= $0 }) ?? true else {
            fail("诊断时钟无效或发生倒退", at: now)
            return
        }
        lastObservedAt = now
        switch phase {
        case .queued(let request, _, let deadline) where now >= deadline:
            fail("\(request.label) 发送等待超过 3 秒", at: now)
        case .awaiting(let request, let deadline) where now >= deadline:
            fail("\(request.label) 应答等待超过 3 秒", at: now)
        default:
            break
        }
    }

    private mutating func enqueue(_ request: Request, after delay: TimeInterval, at now: TimeInterval) {
        let notBefore = now + delay
        let deadline = notBefore + 3
        guard notBefore.isFinite, notBefore > now,
              deadline.isFinite, deadline > notBefore else {
            fail("诊断时钟无法建立发送期限", at: now)
            return
        }
        phase = .queued(request, notBefore: notBefore, deadline: deadline)
        record("QUEUED \(request.label); not-before \(notBefore)", at: now)
    }

    private mutating func allowedCommand(for request: Request, at now: TimeInterval) -> Data? {
        guard let command = request.command,
              command == DPI.readBase || ControllerMemoryProtocol.isReadCommand(command) else {
            fail("诊断拒绝了读取白名单以外的命令", at: now)
            return nil
        }
        return command
    }

    private mutating func fail(_ reason: String, at now: TimeInterval) {
        guard !isFinished else { return }
        failure = reason
        isFinished = true
        phase = .finished
        record("FAILED \(reason)", at: now)
    }

    private mutating func record(_ message: String, at now: TimeInterval) {
        trace.append(String(format: "%.3f", now) + " " + message)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
