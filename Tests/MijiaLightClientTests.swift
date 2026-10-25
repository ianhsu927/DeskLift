import CommonCrypto
import Foundation
import XCTest

private final class FakeMijiaTransport: MijiaLightTransport {
    static let did: UInt32 = 1_234_567_890
    static let token = Data((0..<16).map(UInt8.init))
    var model = "xiaomi.light.bar2"
    var handshakeID = did
    var states: [MijiaLightState] = [MijiaLightState(isOn: true, brightness: 50, colorTemperature: 4000, mode: 0)]
    var methods = [String]()
    var setParameters = [[String: Any]]()
    var timeoutOnWrite = false
    var invalidAcknowledgement = false
    var wrongResponseID = false
    var closed = false
    var afterExchange: ((String) -> Void)?

    func close() { closed = true }

    func exchange(_ request: Data, timeout: TimeInterval) throws -> Data {
        XCTAssertGreaterThan(timeout, 0)
        XCTAssertLessThanOrEqual(timeout, 2)
        if request == MiIOProtocol.hello {
            return header(length: 32, did: handshakeID, timestamp: 1000) + Data(repeating: 0xff, count: 16)
        }
        let clear = try crypt(Data(request.dropFirst(32)), encrypt: false)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: clear) as? [String: Any])
        let method = try XCTUnwrap(envelope["method"] as? String)
        let requestID = try XCTUnwrap(envelope["id"] as? Int)
        methods.append(method)
        let result: Any
        switch method {
        case "miIO.info":
            result = ["model": model, "fw_ver": "test-1.0"]
        case "get_properties":
            let state = states.count > 1 ? states.removeFirst() : states[0]
            let values: [Any] = [state.isOn, state.brightness, state.colorTemperature, state.mode]
            result = (1...4).map { ["did": String(Self.did), "siid": 2, "piid": $0,
                                   "code": 0, "value": values[$0 - 1]] as [String: Any] }
        case "set_properties":
            let params = try XCTUnwrap(envelope["params"] as? [[String: Any]])
            setParameters.append(contentsOf: params)
            if timeoutOnWrite { throw MijiaLightClientError.timedOut }
            let piid = try XCTUnwrap(params.first?["piid"] as? Int)
            result = [["did": String(Self.did), "siid": 2,
                       "piid": invalidAcknowledgement ? 99 : piid, "code": 0]]
        default:
            XCTFail("Unexpected RPC: \(method)")
            throw MijiaLightClientError.invalidAcknowledgement
        }
        let response = try JSONSerialization.data(withJSONObject: ["id": requestID + (wrongResponseID ? 1 : 0), "result": result])
        let encrypted = try crypt(response, encrypt: true)
        var prefix = header(length: 32 + encrypted.count, did: Self.did, timestamp: 1000)
        let checksum = md5(prefix + Self.token + encrypted)
        prefix.append(checksum)
        prefix.append(encrypted)
        afterExchange?(method)
        return prefix
    }

    private func header(length: Int, did: UInt32, timestamp: UInt32) -> Data {
        var result = Data([0x21, 0x31, UInt8(length >> 8), UInt8(length & 0xff), 0, 0, 0, 0])
        for number in [did, timestamp] {
            result.append(contentsOf: [UInt8((number >> 24) & 255), UInt8((number >> 16) & 255),
                                       UInt8((number >> 8) & 255), UInt8(number & 255)])
        }
        return result
    }

    private func md5(_ input: Data) -> Data {
        var result = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = input.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(input.count), &result) }
        return Data(result)
    }

    private func crypt(_ input: Data, encrypt: Bool) throws -> Data {
        let key = md5(Self.token)
        let iv = md5(key + Self.token)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var count = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            input.withUnsafeBytes { inputBuffer in
                key.withUnsafeBytes { keyBuffer in
                    iv.withUnsafeBytes { ivBuffer in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding), keyBuffer.baseAddress, key.count,
                                ivBuffer.baseAddress, inputBuffer.baseAddress, input.count,
                                outputBuffer.baseAddress, outputBuffer.count, &count)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw MiIOProtocolError.invalidPacket }
        return Data(output.prefix(count))
    }
}

final class MijiaLightClientTests: XCTestCase {
    private func credentials(confirmed: Bool = true) throws -> MijiaLightCredentials {
        try MijiaLightCredentials(host: "192.168.1.100", tokenHex: FakeMijiaTransport.token.map { String(format: "%02x", $0) }.joined(),
                                 deviceID: confirmed ? FakeMijiaTransport.did : nil)
    }

    private func client(_ fake: FakeMijiaTransport) -> MijiaLightClient {
        MijiaLightClient(transportFactory: { _ in fake }, sleep: { _ in })
    }

    func testReadLearnsIdentityWithoutSendingWrites() async throws {
        let fake = FakeMijiaTransport()
        let result = try await client(fake).read(credentials(confirmed: false))
        XCTAssertEqual(result.deviceID, FakeMijiaTransport.did)
        XCTAssertEqual(result.firmware, "test-1.0")
        XCTAssertEqual(result.state, fake.states[0])
        XCTAssertEqual(fake.methods, ["miIO.info", "get_properties"])
        XCTAssertTrue(fake.setParameters.isEmpty)
        XCTAssertTrue(fake.closed)
    }

    func testWriteRequiresConfirmedIdentityBeforeOpeningTransport() async throws {
        var opened = false
        let service = MijiaLightClient(transportFactory: { _ in opened = true; return FakeMijiaTransport() }, sleep: { _ in })
        do {
            _ = try await service.set(.power(false), using: credentials(confirmed: false))
            XCTFail("Unconfirmed device must not be controlled")
        } catch MijiaLightClientError.deviceIdentityRequired { }
        XCTAssertFalse(opened)
    }

    func testAbsoluteWriteOnceAndVerifiedReadback() async throws {
        let fake = FakeMijiaTransport()
        let target = MijiaLightState(isOn: true, brightness: 30, colorTemperature: 4000, mode: 0)
        fake.states.append(target)
        let result = try await client(fake).set(.brightness(30), using: credentials())
        XCTAssertEqual(result.state, target)
        XCTAssertEqual(fake.methods, ["miIO.info", "get_properties", "set_properties", "get_properties"])
        XCTAssertEqual(fake.setParameters.count, 1)
        XCTAssertEqual(fake.setParameters[0]["value"] as? Int, 30)
        XCTAssertTrue(fake.closed)
    }

    func testTransitionAllowsOnlyTwoReadbacksAndOneWrite() async throws {
        let fake = FakeMijiaTransport()
        do {
            _ = try await client(fake).set(.power(false), using: credentials())
            XCTFail("Unchanged state must not be reported as success")
        } catch MijiaLightClientError.readbackMismatch { }
        XCTAssertEqual(fake.methods.filter { $0 == "set_properties" }.count, 1)
        XCTAssertEqual(fake.methods.filter { $0 == "get_properties" }.count, 3)
    }

    func testLostWriteAcknowledgementNeverRetriesWrite() async throws {
        let fake = FakeMijiaTransport()
        fake.timeoutOnWrite = true
        do {
            _ = try await client(fake).set(.power(false), using: credentials())
            XCTFail("A missing ACK must fail")
        } catch MijiaLightClientError.timedOut { }
        XCTAssertEqual(fake.methods, ["miIO.info", "get_properties", "set_properties"])
        XCTAssertEqual(fake.setParameters.count, 1)
        XCTAssertTrue(fake.closed)
    }

    func testWrongModelOrIdentityNeverWrites() async throws {
        for wrongIdentity in [false, true] {
            let fake = FakeMijiaTransport()
            if wrongIdentity { fake.handshakeID += 1 } else { fake.model = "other.light.model" }
            do {
                _ = try await client(fake).set(.power(false), using: credentials())
                XCTFail("Unexpected device must not be controlled")
            } catch { }
            XCTAssertTrue(fake.setParameters.isEmpty)
            XCTAssertTrue(fake.closed)
        }
    }

    func testMismatchedResponseIDFailsWithoutWrite() async throws {
        let fake = FakeMijiaTransport()
        fake.wrongResponseID = true
        do {
            _ = try await client(fake).set(.power(false), using: credentials())
            XCTFail("Mismatched reply must fail")
        } catch MiIOProtocolError.unexpectedResponse { }
        XCTAssertEqual(fake.methods, ["miIO.info"])
        XCTAssertTrue(fake.setParameters.isEmpty)
    }

    func testInvalidAcknowledgementNeverRetriesOrReadsFurther() async throws {
        let fake = FakeMijiaTransport()
        fake.invalidAcknowledgement = true
        do {
            _ = try await client(fake).set(.power(false), using: credentials())
            XCTFail("Mismatched write ACK must fail")
        } catch MijiaLightClientError.invalidAcknowledgement { }
        XCTAssertEqual(fake.methods, ["miIO.info", "get_properties", "set_properties"])
        XCTAssertEqual(fake.setParameters.count, 1)
    }

    func testTotalDeadlinePreventsWriteEvenWhenIndividualRepliesSucceed() async throws {
        let fake = FakeMijiaTransport()
        var now: TimeInterval = 0
        fake.afterExchange = { method in if method == "get_properties" { now = 16 } }
        let service = MijiaLightClient(transportFactory: { _ in fake }, clock: { now }, sleep: { _ in })
        do {
            _ = try await service.set(.power(false), using: credentials())
            XCTFail("Expired operation must not write")
        } catch MijiaLightClientError.operationTimedOut { }
        XCTAssertEqual(fake.methods, ["miIO.info", "get_properties"])
        XCTAssertTrue(fake.setParameters.isEmpty)
    }
}
