import CommonCrypto
import CoreFoundation
import Foundation

enum MiIOProtocolError: Error, LocalizedError, Equatable {
    case invalidHost
    case invalidToken
    case invalidDeviceID
    case invalidRequest
    case invalidPacket
    case invalidChecksum
    case unexpectedResponse
    case invalidResponse
    case invalidState
    case unsupportedDevice
    case rpc(Int)

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "请输入挂灯在局域网中的 IPv4 地址"
        case .invalidToken: return "设备 Token 必须是有效的 32 位十六进制字符"
        case .invalidDeviceID: return "设备标识无效"
        case .invalidRequest: return "挂灯请求参数无效"
        case .invalidPacket: return "挂灯响应数据格式无效"
        case .invalidChecksum: return "挂灯响应认证失败，请检查设备 Token"
        case .unexpectedResponse: return "挂灯响应与当前请求不匹配"
        case .invalidResponse: return "挂灯未返回有效结果"
        case .invalidState: return "挂灯状态无效或不完整"
        case .unsupportedDevice: return "此设备不是米家显示器挂灯 2"
        case .rpc(let code): return "挂灯返回错误代码 \(code)"
        }
    }
}

struct MijiaLightCredentials: Codable, Equatable {
    let host: String
    let token: Data
    let deviceID: UInt32?

    init(host: String, tokenHex: String, deviceID: UInt32? = nil) throws {
        guard Self.isPrivateIPv4(host) else { throw MiIOProtocolError.invalidHost }
        let characters = Array(tokenHex.utf8)
        guard characters.count == 32 else { throw MiIOProtocolError.invalidToken }
        var token = Data()
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let high = Self.hexDigit(characters[index]),
                  let low = Self.hexDigit(characters[index + 1]) else {
                throw MiIOProtocolError.invalidToken
            }
            token.append(high * 16 + low)
        }
        try MiIOProtocol.validateToken(token)
        if let deviceID { try MiIOProtocol.validateDeviceID(deviceID) }
        self.host = host
        self.token = token
        self.deviceID = deviceID
    }

    var tokenHex: String { token.map { String(format: "%02x", $0) }.joined() }

    private enum CodingKeys: String, CodingKey { case host, token, deviceID }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let host = try values.decode(String.self, forKey: .host)
        let token = try values.decode(Data.self, forKey: .token)
        let deviceID = try values.decodeIfPresent(UInt32.self, forKey: .deviceID)
        let hex = token.map { String(format: "%02x", $0) }.joined()
        try self.init(host: host, tokenHex: hex, deviceID: deviceID)
    }

    private static func hexDigit(_ character: UInt8) -> UInt8? {
        switch character {
        case 48...57: return character - 48
        case 65...70: return character - 65 + 10
        case 97...102: return character - 97 + 10
        default: return nil
        }
    }

    private static func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        var octets = [UInt8]()
        for part in parts {
            guard !part.isEmpty, part.utf8.allSatisfy({ (48...57).contains($0) }),
                  part.count == 1 || part.first != "0", let octet = UInt8(part) else {
                return false
            }
            octets.append(octet)
        }
        return octets[0] == 10
            || (octets[0] == 172 && (16...31).contains(octets[1]))
            || (octets[0] == 192 && octets[1] == 168)
    }
}

struct MijiaLightState: Equatable {
    let isOn: Bool
    let brightness: Int
    let colorTemperature: Int
    let mode: Int
}

enum MijiaLightProperty: Equatable {
    case power(Bool)
    case brightness(Int)
    case colorTemperature(Int)
}

struct MiIOHandshake {
    let deviceID: UInt32
    let timestamp: UInt32
}

// Independent implementation of the miIO packet format exercised by the local
// read/write diagnostics. This file contains no networking or automatic retries.
enum MiIOProtocol {
    static let hello = Data([0x21, 0x31, 0x00, 0x20] + [UInt8](repeating: 0xff, count: 28))
    private static let maximumPacketSize = 8192

    static func parseHandshake(_ data: Data, expectedDeviceID: UInt32?) throws -> MiIOHandshake {
        let header = try parseHeader(data)
        guard data.count == 32 else { throw MiIOProtocolError.invalidPacket }
        if let expectedDeviceID {
            try validateDeviceID(expectedDeviceID)
            guard header.deviceID == expectedDeviceID else { throw MiIOProtocolError.unexpectedResponse }
        }
        // Bound-device hello checksums are often all FF. Authentication is
        // established only by a subsequent response validated with the token.
        return header
    }

    static func encodeRequest(method: String, params: [[String: Any]], id: Int,
                              token: Data, deviceID: UInt32, timestamp: UInt32) throws -> Data {
        try validateToken(token)
        try validateDeviceID(deviceID)
        guard (1...Int(Int32.max)).contains(id), timestamp != UInt32.max else {
            throw MiIOProtocolError.invalidRequest
        }
        try validateParams(method: method, params: params, deviceID: deviceID)
        let payload: [String: Any] = ["id": id, "method": method, "params": params]
        guard JSONSerialization.isValidJSONObject(payload),
              let clear = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw MiIOProtocolError.invalidRequest
        }
        let encrypted = try crypt(clear, token: token, encrypt: true)
        guard encrypted.count + 32 <= maximumPacketSize else { throw MiIOProtocolError.invalidRequest }
        var header = Data([0x21, 0x31])
        append(UInt16(encrypted.count + 32), to: &header)
        append(UInt32(0), to: &header)
        append(deviceID, to: &header)
        append(timestamp, to: &header)
        return header + md5(header + token + encrypted) + encrypted
    }

    static func decodeResponse(_ data: Data, id: Int, token: Data,
                               deviceID: UInt32, timestamp: UInt32) throws -> Any {
        try validateToken(token)
        try validateDeviceID(deviceID)
        guard (1...Int(Int32.max)).contains(id), timestamp != UInt32.max else {
            throw MiIOProtocolError.invalidRequest
        }
        let header = try parseHeader(data)
        guard header.deviceID == deviceID,
              abs(Int64(header.timestamp) - Int64(timestamp)) <= 60 else {
            throw MiIOProtocolError.unexpectedResponse
        }
        let bytes = Array(data)
        let encrypted = Data(bytes.dropFirst(32))
        guard !encrypted.isEmpty, encrypted.count % 16 == 0 else {
            throw MiIOProtocolError.invalidPacket
        }
        let expected = md5(Data(bytes.prefix(16)) + token + encrypted)
        var difference: UInt8 = 0
        for (received, computed) in zip(bytes[16..<32], expected) { difference |= received ^ computed }
        guard difference == 0 else { throw MiIOProtocolError.invalidChecksum }
        var clear = try crypt(encrypted, token: token, encrypt: false)
        while clear.last == 0 { clear.removeLast() }
        guard let response = (try? JSONSerialization.jsonObject(with: clear)) as? [String: Any],
              let responseID = integer(response["id"]) else {
            throw MiIOProtocolError.invalidResponse
        }
        guard responseID == id else { throw MiIOProtocolError.unexpectedResponse }
        if let rawError = response["error"] {
            guard let error = rawError as? [String: Any], let code = integer(error["code"]),
                  (Int(Int32.min)...Int(Int32.max)).contains(code) else {
                throw MiIOProtocolError.invalidResponse
            }
            throw MiIOProtocolError.rpc(code)
        }
        guard let result = response["result"], !(result is NSNull) else {
            throw MiIOProtocolError.invalidResponse
        }
        return result
    }

    static func readParams(deviceID: UInt32) -> [[String: Any]] {
        (1...4).map { ["did": String(deviceID), "siid": 2, "piid": $0] }
    }

    static func writeParams(property: MijiaLightProperty, deviceID: UInt32) throws -> [[String: Any]] {
        try validateDeviceID(deviceID)
        let piid: Int
        let value: Any
        switch property {
        case .power(let isOn):
            piid = 1
            value = isOn
        case .brightness(let brightness):
            guard (1...100).contains(brightness) else { throw MiIOProtocolError.invalidRequest }
            piid = 2
            value = brightness
        case .colorTemperature(let temperature):
            guard (2700...6500).contains(temperature) else { throw MiIOProtocolError.invalidRequest }
            piid = 3
            value = temperature
        }
        return [["did": String(deviceID), "siid": 2, "piid": piid, "value": value]]
    }

    static func parseState(_ result: Any, deviceID: UInt32) throws -> MijiaLightState {
        try validateDeviceID(deviceID)
        guard let records = result as? [[String: Any]], records.count == 4 else {
            throw MiIOProtocolError.invalidState
        }
        var values = [Int: Any]()
        for record in records {
            guard matchesDeviceID(record["did"], deviceID), integer(record["siid"]) == 2,
                  let piid = integer(record["piid"]), (1...4).contains(piid), values[piid] == nil,
                  let code = integer(record["code"]), (Int(Int32.min)...Int(Int32.max)).contains(code) else {
                throw MiIOProtocolError.invalidState
            }
            guard code == 0 else { throw MiIOProtocolError.rpc(code) }
            guard let value = record["value"] else { throw MiIOProtocolError.invalidState }
            values[piid] = value
        }
        guard let isOn = boolean(values[1]), let brightness = integer(values[2]),
              (1...100).contains(brightness), let temperature = integer(values[3]),
              (2700...6500).contains(temperature), let mode = integer(values[4]), (0...4).contains(mode) else {
            throw MiIOProtocolError.invalidState
        }
        return MijiaLightState(isOn: isOn, brightness: brightness, colorTemperature: temperature, mode: mode)
    }

    static func validateInfo(_ result: Any) throws -> String {
        guard let info = result as? [String: Any], let model = info["model"] as? String else {
            throw MiIOProtocolError.invalidResponse
        }
        guard model == "xiaomi.light.bar2" else { throw MiIOProtocolError.unsupportedDevice }
        guard let firmware = info["fw_ver"] as? String, !firmware.isEmpty, firmware.utf8.count <= 128,
              firmware.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw MiIOProtocolError.invalidResponse
        }
        return firmware
    }

    fileprivate static func validateToken(_ token: Data) throws {
        guard token.count == 16, token.contains(where: { $0 != 0 }), token.contains(where: { $0 != 0xff }) else {
            throw MiIOProtocolError.invalidToken
        }
    }

    fileprivate static func validateDeviceID(_ deviceID: UInt32) throws {
        guard deviceID != 0, deviceID != UInt32.max else { throw MiIOProtocolError.invalidDeviceID }
    }

    private static func validateParams(method: String, params: [[String: Any]], deviceID: UInt32) throws {
        switch method {
        case "miIO.info":
            guard params.isEmpty else { throw MiIOProtocolError.invalidRequest }
        case "get_properties":
            guard (1...4).contains(params.count) else { throw MiIOProtocolError.invalidRequest }
            var seen = Set<Int>()
            for item in params {
                guard Set(item.keys) == Set(["did", "siid", "piid"]),
                      matchesDeviceID(item["did"], deviceID), integer(item["siid"]) == 2,
                      let piid = integer(item["piid"]), (1...4).contains(piid), seen.insert(piid).inserted else {
                    throw MiIOProtocolError.invalidRequest
                }
            }
        case "set_properties":
            guard params.count == 1, let item = params.first,
                  Set(item.keys) == Set(["did", "siid", "piid", "value"]),
                  matchesDeviceID(item["did"], deviceID), integer(item["siid"]) == 2,
                  let piid = integer(item["piid"]) else { throw MiIOProtocolError.invalidRequest }
            switch piid {
            case 1: guard boolean(item["value"]) != nil else { throw MiIOProtocolError.invalidRequest }
            case 2: guard let value = integer(item["value"]), (1...100).contains(value) else {
                throw MiIOProtocolError.invalidRequest
            }
            case 3: guard let value = integer(item["value"]), (2700...6500).contains(value) else {
                throw MiIOProtocolError.invalidRequest
            }
            default: throw MiIOProtocolError.invalidRequest
            }
        default: throw MiIOProtocolError.invalidRequest
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)),
              number.compare(NSNumber(value: Int.min)) != .orderedAscending,
              number.compare(NSNumber(value: Int.max)) != .orderedDescending else { return nil }
        return number.intValue
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func matchesDeviceID(_ value: Any?, _ deviceID: UInt32) -> Bool {
        if let string = value as? String { return string == String(deviceID) }
        return integer(value) == Int(deviceID)
    }

    private static func parseHeader(_ data: Data) throws -> MiIOHandshake {
        let bytes = Array(data)
        guard (32...maximumPacketSize).contains(bytes.count), bytes[0] == 0x21, bytes[1] == 0x31,
              (Int(bytes[2]) << 8 | Int(bytes[3])) == bytes.count,
              bytes[4..<8].allSatisfy({ $0 == 0 }) else { throw MiIOProtocolError.invalidPacket }
        let deviceID = uint32(bytes, at: 8)
        let timestamp = uint32(bytes, at: 12)
        guard deviceID != 0, deviceID != UInt32.max, timestamp != UInt32.max else {
            throw MiIOProtocolError.invalidPacket
        }
        return MiIOHandshake(deviceID: deviceID, timestamp: timestamp)
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { ($0 << 8) | UInt32(bytes[index + $1]) }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func md5(_ data: Data) -> Data {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return Data(digest)
    }

    private static func crypt(_ data: Data, token: Data, encrypt: Bool) throws -> Data {
        let key = md5(token)
        let iv = md5(key + token)
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let capacity = output.count
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    data.withUnsafeBytes { inputBytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress, inputBytes.baseAddress, data.count,
                                outputBytes.baseAddress, capacity, &written)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MiIOProtocolError.invalidPacket }
        return Data(output.prefix(written))
    }
}
