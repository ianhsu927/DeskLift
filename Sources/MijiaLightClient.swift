import Foundation
import CoreFoundation
import Darwin

struct MijiaLightReading {
    let state: MijiaLightState
    let deviceID: UInt32
    let firmware: String
}

protocol MijiaLightServicing {
    func read(_ credentials: MijiaLightCredentials) async throws -> MijiaLightReading
    func set(_ property: MijiaLightProperty, using credentials: MijiaLightCredentials) async throws -> MijiaLightReading
}

enum MijiaLightClientError: LocalizedError {
    case invalidHost
    case socketFailure(Int32)
    case timedOut
    case operationTimedOut
    case deviceIdentityRequired
    case invalidAcknowledgement
    case readbackMismatch

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "请输入挂灯的有效局域网 IPv4 地址。"
        case .socketFailure: return "无法与挂灯进行局域网通信，请检查地址和网络。"
        case .timedOut: return "挂灯响应超时；未重发控制命令。"
        case .operationTimedOut: return "挂灯操作已达到时间上限；未重发控制命令。"
        case .deviceIdentityRequired: return "请先读取并确认挂灯身份，再进行控制。"
        case .invalidAcknowledgement: return "挂灯未确认本次设置，请刷新查看实际状态。"
        case .readbackMismatch: return "挂灯读回状态与设置不一致，请刷新查看实际状态。"
        }
    }
}

// Each exchange sends exactly one datagram. Connected UDP admits replies only
// from the selected IP and port. Neither the transport nor the client retries.
protocol MijiaLightTransport: AnyObject {
    func exchange(_ request: Data, timeout: TimeInterval) throws -> Data
    func close()
}

private final class MijiaUDPTransport: MijiaLightTransport {
    private var descriptor: Int32 = -1

    init(host: String) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(54321).bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else {
            throw MijiaLightClientError.invalidHost
        }
        descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else { throw MijiaLightClientError.socketFailure(errno) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close()
            throw MijiaLightClientError.socketFailure(code)
        }
    }

    deinit { close() }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func configureTimeout(_ duration: TimeInterval, option: Int32) throws {
        let micros = max(1, Int(duration * 1_000_000))
        var timeout = timeval(tv_sec: micros / 1_000_000, tv_usec: Int32(micros % 1_000_000))
        guard setsockopt(descriptor, SOL_SOCKET, option, &timeout,
                         socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw MijiaLightClientError.socketFailure(errno)
        }
    }

    func exchange(_ request: Data, timeout: TimeInterval) throws -> Data {
        guard descriptor >= 0 else { throw MijiaLightClientError.socketFailure(EBADF) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try configureTimeout(timeout, option: SO_SNDTIMEO)
        let sent = request.withUnsafeBytes { bytes in
            Darwin.send(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard sent == request.count else { throw transportError() }
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw MijiaLightClientError.timedOut }
        try configureTimeout(remaining, option: SO_RCVTIMEO)
        var buffer = [UInt8](repeating: 0, count: 65_535)
        let received = buffer.withUnsafeMutableBytes { bytes in
            Darwin.recv(descriptor, bytes.baseAddress, bytes.count, 0)
        }
        guard received > 0 else { throw transportError() }
        return Data(buffer.prefix(received))
    }

    private func transportError() -> MijiaLightClientError {
        let code = errno
        return code == EAGAIN || code == EWOULDBLOCK || code == ETIMEDOUT
            ? .timedOut : .socketFailure(code)
    }
}

// The only mutable field is protected by lock.
private final class MijiaLightCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }
}

// Configuration is immutable; every transport/session is confined to queue.
final class MijiaLightClient: MijiaLightServicing, @unchecked Sendable {
    typealias TransportFactory = (String) throws -> MijiaLightTransport
    private let queue = DispatchQueue(label: "local.ian.desklift.mijia-light", qos: .userInitiated)
    private let transportFactory: TransportFactory
    private let clock: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void
    private let operationTimeout: TimeInterval

    init(transportFactory: TransportFactory? = nil,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
         operationTimeout: TimeInterval = 15) {
        self.transportFactory = transportFactory ?? { try MijiaUDPTransport(host: $0) }
        self.clock = clock
        self.sleep = sleep
        self.operationTimeout = max(0.01, min(operationTimeout, 30))
    }

    func read(_ credentials: MijiaLightCredentials) async throws -> MijiaLightReading {
        try await perform(credentials, property: nil)
    }

    func set(_ property: MijiaLightProperty, using credentials: MijiaLightCredentials) async throws -> MijiaLightReading {
        guard credentials.deviceID != nil else { throw MijiaLightClientError.deviceIdentityRequired }
        return try await perform(credentials, property: property)
    }

    private func perform(_ credentials: MijiaLightCredentials, property: MijiaLightProperty?) async throws -> MijiaLightReading {
        try Task.checkCancellation()
        let cancellation = MijiaLightCancellation()
        let deadline = clock() + operationTimeout
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let reading = try self.run(credentials, property: property, cancellation: cancellation, deadline: deadline)
                        continuation.resume(returning: reading)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }, onCancel: { cancellation.cancel() })
    }

    private func run(_ credentials: MijiaLightCredentials, property: MijiaLightProperty?,
                     cancellation: MijiaLightCancellation, deadline: TimeInterval) throws -> MijiaLightReading {
        func check() throws {
            try cancellation.check()
            if clock() >= deadline { throw MijiaLightClientError.operationTimedOut }
        }
        try check()
        let transport = try transportFactory(credentials.host)
        defer { transport.close() }
        func exchange(_ packet: Data) throws -> Data {
            try check()
            let remaining = deadline - clock()
            guard remaining > 0 else { throw MijiaLightClientError.operationTimedOut }
            let result = try transport.exchange(packet, timeout: min(2, remaining))
            try check()
            return result
        }
        let hello = try MiIOProtocol.parseHandshake(exchange(MiIOProtocol.hello),
                                                     expectedDeviceID: credentials.deviceID)
        let started = clock()
        var requestID = Int.random(in: 1...1_000_000_000)
        func rpc(_ method: String, _ params: [[String: Any]]) throws -> Any {
            try check()
            requestID += 1
            let elapsed = max(0, clock() - started)
            guard elapsed < Double(UInt32.max - hello.timestamp) else {
                throw MijiaLightClientError.operationTimedOut
            }
            let timestamp = hello.timestamp + UInt32(elapsed)
            let packet = try MiIOProtocol.encodeRequest(method: method, params: params, id: requestID,
                                                        token: credentials.token, deviceID: hello.deviceID,
                                                        timestamp: timestamp)
            return try MiIOProtocol.decodeResponse(exchange(packet), id: requestID, token: credentials.token,
                                                   deviceID: hello.deviceID, timestamp: timestamp)
        }
        let firmware = try MiIOProtocol.validateInfo(rpc("miIO.info", []))
        func readState() throws -> MijiaLightState {
            try MiIOProtocol.parseState(rpc("get_properties", MiIOProtocol.readParams(deviceID: hello.deviceID)),
                                         deviceID: hello.deviceID)
        }
        let initial = try readState()
        guard let property else {
            return MijiaLightReading(state: initial, deviceID: hello.deviceID, firmware: firmware)
        }
        // A write requires a previously confirmed identity and a fresh state
        // from this very socket/session. The absolute-value command is sent once.
        guard credentials.deviceID == hello.deviceID else { throw MijiaLightClientError.deviceIdentityRequired }
        let params = try MiIOProtocol.writeParams(property: property, deviceID: hello.deviceID)
        let acknowledgement = try rpc("set_properties", params)
        try validateAcknowledgement(acknowledgement, params: params, deviceID: hello.deviceID)
        for attempt in 0..<2 {
            try check()
            let delay: TimeInterval = attempt == 0 ? 0.25 : 0.5
            guard deadline - clock() > delay else { throw MijiaLightClientError.operationTimedOut }
            sleep(delay)
            let state = try readState()
            if matches(property, state: state) {
                return MijiaLightReading(state: state, deviceID: hello.deviceID, firmware: firmware)
            }
        }
        throw MijiaLightClientError.readbackMismatch
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { return nil }
        return number.intValue
    }

    private func matchesDeviceID(_ value: Any?, expected: UInt32) -> Bool {
        if let string = value as? String { return string == String(expected) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return false }
        return number.doubleValue == Double(expected)
    }

    private func validateAcknowledgement(_ result: Any, params: [[String: Any]], deviceID: UInt32) throws {
        guard let items = result as? [[String: Any]], items.count == 1,
              let item = items.first, let expected = params.first,
              matchesDeviceID(item["did"], expected: deviceID),
              integer(item["siid"]) == 2,
              let piid = integer(item["piid"]), piid == integer(expected["piid"]),
              integer(item["code"]) == 0 else {
            throw MijiaLightClientError.invalidAcknowledgement
        }
    }

    private func matches(_ property: MijiaLightProperty, state: MijiaLightState) -> Bool {
        switch property {
        case .power(let value): return state.isOn == value
        case .brightness(let value): return state.brightness == value
        case .colorTemperature(let value): return state.colorTemperature == value
        }
    }
}
