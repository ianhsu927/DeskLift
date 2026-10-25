import Foundation
import XCTest

final class MiIOProtocolTests: XCTestCase {
    private let tokenHex = "00112233445566778899aabbccddeeff"
    private let deviceID: UInt32 = 1_234_567_890
    private let timestamp: UInt32 = 0x10203040

    // Fixed fixtures generated independently with Python hashlib, struct and
    // PyCryptodome AES-CBC, using sorted compact JSON and this synthetic token.
    private let infoRequest = "2131005000000000499602d210203040b721d8ec1394bafe9be5567d369e032ebd6a2ee30f2a04a15abd54fee183e08702c338cdda7e868b181c8d435076525c8c3f69a2c25308bb136a487b2c0e84e7"
    private let stateResponse = "2131013000000000499602d210203040ee9b7f4a85e03662d95c5d59526c85baad4cfc4c6a37114f4d5edc1e6685648afdfc793a93387cceff343b96bec0bc2b000520b4304ba9aaeea7e130d342c6c5b4df76172916accfb2f7986b106e22dbb567406c63a0fd3e32bc53a4e60df48affe0db9c28925ef6479d909f5dbca9508f5886d911381f9496ee044d61bb23c3b229bf13f687f689b6fbebb9cf423c5b3418ca14db9c3a9ba854f6e90a0858a309df9544af9d5e3358c6266a0c30be02ef718b58b2decd559dc1e97941fc31d20ca5fd18a427cb33243f8022ac1a56dc7b33577f74eb3f0233860e6a388515e9f5ad3cd50e1f6f11cd7904a62e188f4f781f5f8d332ad6677e3a0cd82bcd79b0ffd163a5fc88967bdf1914bff55493d7defcb77a944571eac75d9d99affdaaf5"
    private let infoResponse = "2131007000000000499602d2102030408fa5a5421b6aa80bad1a7aac4fe20536ad4cfc4c6a37114f4d5edc1e6685648a02ab47642a751d9e194a0bdcb028f049d76b24c33a5d6cc22bcb2e38d7ea2ff9cacac6f2657c14c8bedae388195777e434c7649a25d3e78fc50bf4165890572a"
    private let rpcErrorResponse = "2131007000000000499602d21020304055e409e7d27b451c8177d87bcf02660ece77cc6af1e40674a04986d4fae878ad824ae426ab9b119a33ee2cdfe34ab8ef4d7834dff9d5a315822fe4d237f16fc9d40021c7e25d9adedba957220a2cc1abb0f45cf476c6e32760aac76adf1919fa"

    func testCredentialsAcceptOnlyCanonicalRFC1918HostsAndProvisionedTokens() throws {
        for host in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.1.100"] {
            let credentials = try MijiaLightCredentials(host: host, tokenHex: tokenHex.uppercased(), deviceID: deviceID)
            XCTAssertEqual(credentials.host, host)
            XCTAssertEqual(credentials.tokenHex, tokenHex)
            XCTAssertEqual(credentials.token.count, 16)
            XCTAssertEqual(try JSONDecoder().decode(MijiaLightCredentials.self,
                                                   from: JSONEncoder().encode(credentials)), credentials)
        }
        for host in ["localhost", "example.com", "8.8.8.8", "127.0.0.1", "169.254.1.1", "100.64.1.1",
                     "172.15.1.1", "172.32.1.1", "192.169.1.1", "192.168.001.1", "192.168.1.256",
                     "192.168.1", "192.168.1.1 ", "::1", "192.168.1.1:54321"] {
            XCTAssertThrowsError(try MijiaLightCredentials(host: host, tokenHex: tokenHex))
        }
        for invalid in ["", String(tokenHex.dropLast()), tokenHex + "0", String(repeating: "0", count: 32),
                        String(repeating: "F", count: 32), String(repeating: "g", count: 32), " " + tokenHex] {
            XCTAssertThrowsError(try MijiaLightCredentials(host: "192.168.1.2", tokenHex: invalid))
        }
        for invalidID in [UInt32(0), UInt32.max] {
            XCTAssertThrowsError(try MijiaLightCredentials(host: "192.168.1.2", tokenHex: tokenHex, deviceID: invalidID))
        }
    }

    func testCredentialDecodingCannotBypassValidation() throws {
        let invalid: [String: Any] = ["host": "192.168.1.2", "token": Data(repeating: 0, count: 16).base64EncodedString()]
        XCTAssertThrowsError(try JSONDecoder().decode(MijiaLightCredentials.self,
                                                     from: JSONSerialization.data(withJSONObject: invalid)))
    }

    func testHandshakeValidatesLayoutIdentityAndSentinels() throws {
        let response = data("2131002000000000499602d210203040" + String(repeating: "ff", count: 16))
        let handshake = try MiIOProtocol.parseHandshake(response, expectedDeviceID: deviceID)
        XCTAssertEqual(handshake.deviceID, deviceID)
        XCTAssertEqual(handshake.timestamp, timestamp)
        XCTAssertEqual(try MiIOProtocol.parseHandshake(response, expectedDeviceID: nil).deviceID, deviceID)
        XCTAssertEqual(MiIOProtocol.hello, data("21310020" + String(repeating: "ff", count: 28)))
        XCTAssertThrowsError(try MiIOProtocol.parseHandshake(response, expectedDeviceID: deviceID + 1))
        for index in [0, 2, 4, 8, 12] {
            var corrupt = response
            corrupt[index] ^= 1
            if index == 8 || index == 12 {
                // A different valid DID/timestamp is still parseable discovery
                // data; a known device ID is enforced separately above.
                continue
            }
            XCTAssertThrowsError(try MiIOProtocol.parseHandshake(corrupt, expectedDeviceID: deviceID))
        }
        XCTAssertThrowsError(try MiIOProtocol.parseHandshake(Data(response.prefix(31)), expectedDeviceID: deviceID))
        XCTAssertThrowsError(try MiIOProtocol.parseHandshake(data(infoResponse), expectedDeviceID: deviceID))
        XCTAssertThrowsError(try MiIOProtocol.parseHandshake(data("21310020000000000000000010203040" + String(repeating: "ff", count: 16)), expectedDeviceID: nil))
        XCTAssertThrowsError(try MiIOProtocol.parseHandshake(data("2131002000000000499602d2ffffffff" + String(repeating: "ff", count: 16)), expectedDeviceID: nil))
    }

    func testRequestMatchesIndependentKnownPacketVector() throws {
        let packet = try MiIOProtocol.encodeRequest(method: "miIO.info", params: [], id: 42,
                                                    token: token, deviceID: deviceID, timestamp: timestamp)
        XCTAssertEqual(packet, data(infoRequest))
        XCTAssertFalse(packet.range(of: token) != nil)
    }

    func testAuthenticatedKnownResponseParsesFourLightProperties() throws {
        let result = try decode(data(stateResponse))
        XCTAssertEqual(try MiIOProtocol.parseState(result, deviceID: deviceID),
                       MijiaLightState(isOn: true, brightness: 80, colorTemperature: 4106, mode: 0))
        XCTAssertEqual(try MiIOProtocol.validateInfo(decode(data(infoResponse))), "1.1.3")
    }

    func testCorruptAndMismatchedResponsesAreRejected() throws {
        let packet = data(stateResponse)
        for index in [0, 2, 4, 8, 12, 16, 31, 32, packet.count - 1] {
            var corrupt = packet
            corrupt[index] ^= 1
            XCTAssertThrowsError(try decode(corrupt))
        }
        XCTAssertThrowsError(try decode(Data(packet.dropLast())))
        XCTAssertThrowsError(try decode(packet + Data([0])))
        XCTAssertThrowsError(try MiIOProtocol.decodeResponse(packet, id: 43, token: token,
                                                          deviceID: deviceID, timestamp: timestamp))
        XCTAssertThrowsError(try MiIOProtocol.decodeResponse(packet, id: 42, token: token,
                                                          deviceID: deviceID + 1, timestamp: timestamp))
        XCTAssertThrowsError(try MiIOProtocol.decodeResponse(packet, id: 42, token: token,
                                                          deviceID: deviceID, timestamp: timestamp + 61))
        XCTAssertThrowsError(try MiIOProtocol.decodeResponse(packet, id: 42,
                                                          token: Data(repeating: 0x12, count: 16),
                                                          deviceID: deviceID, timestamp: timestamp))
    }

    func testRPCErrorSurfacesOnlyNumericCode() {
        XCTAssertThrowsError(try decode(data(rpcErrorResponse))) { error in
            XCTAssertEqual(error as? MiIOProtocolError, .rpc(-9999))
            XCTAssertFalse(error.localizedDescription.contains("secret-token-should-never-appear"))
            XCTAssertFalse(error.localizedDescription.contains(self.tokenHex))
        }
    }

    func testWritesAreSingleBoundedPropertiesAndCannotWriteModesOrOtherServices() throws {
        for property in [MijiaLightProperty.power(false), .power(true), .brightness(1), .brightness(100),
                         .colorTemperature(2700), .colorTemperature(6500)] {
            let params = try MiIOProtocol.writeParams(property: property, deviceID: deviceID)
            XCTAssertEqual(params.count, 1)
            XCTAssertNoThrow(try encode("set_properties", params))
        }
        for property in [MijiaLightProperty.brightness(0), .brightness(101), .brightness(Int.max),
                         .colorTemperature(2699), .colorTemperature(6501), .colorTemperature(Int.min)] {
            XCTAssertThrowsError(try MiIOProtocol.writeParams(property: property, deviceID: deviceID))
        }
        let invalid: [[[String: Any]]] = [
            [["did": String(deviceID), "siid": 2, "piid": 4, "value": 1]],
            [["did": String(deviceID), "siid": 3, "piid": 1, "value": true]],
            [["did": String(deviceID + 1), "siid": 2, "piid": 1, "value": true]],
            [["did": String(deviceID), "siid": 2, "piid": 1, "value": 1]],
            [["did": String(deviceID), "siid": 2, "piid": 2, "value": true]],
            [["did": String(deviceID), "siid": 2, "piid": 2, "value": 50.5]],
            [["did": String(deviceID), "siid": 2, "piid": 2, "value": "50"]],
            [["did": String(deviceID), "siid": true, "piid": 2, "value": 50]],
            [["did": String(deviceID), "siid": 2, "piid": 3, "value": 6501]],
            [["did": String(deviceID), "siid": 2, "piid": 1, "value": true, "extra": "no"]]
        ]
        for params in invalid { XCTAssertThrowsError(try encode("set_properties", params)) }
        let power = try MiIOProtocol.writeParams(property: .power(false), deviceID: deviceID)
        XCTAssertThrowsError(try encode("set_properties", power + power))
        for method in ["toggle", "action", "miIO.config_router", "get_prop", ""] {
            XCTAssertThrowsError(try encode(method, []))
        }
        XCTAssertThrowsError(try encode("miIO.info", power))
        XCTAssertThrowsError(try encode("get_properties", power))
        XCTAssertNoThrow(try encode("get_properties", MiIOProtocol.readParams(deviceID: deviceID)))
    }

    func testStateRequiresExactTypesSuccessfulCodesAndAllFourProperties() throws {
        let valid = properties()
        XCTAssertNoThrow(try MiIOProtocol.parseState(valid, deviceID: deviceID))
        XCTAssertThrowsError(try MiIOProtocol.parseState(Array(valid.dropLast()), deviceID: deviceID))
        XCTAssertThrowsError(try MiIOProtocol.parseState(valid + [valid[0]], deviceID: deviceID))
        var duplicate = valid
        duplicate[3] = valid[0]
        XCTAssertThrowsError(try MiIOProtocol.parseState(duplicate, deviceID: deviceID))
        for (index, field, value) in [(0, "value", 1 as Any), (1, "value", true as Any),
                                     (1, "value", 0 as Any), (1, "value", 101 as Any),
                                     (1, "value", 80.5 as Any), (2, "value", 2699 as Any),
                                     (2, "value", 6501 as Any), (3, "value", 5 as Any),
                                     (3, "value", false as Any), (0, "siid", true as Any),
                                     (0, "piid", "1" as Any), (0, "did", "123" as Any),
                                     (0, "code", true as Any)] {
            var invalid = valid
            invalid[index][field] = value
            XCTAssertThrowsError(try MiIOProtocol.parseState(invalid, deviceID: deviceID))
        }
        var failed = valid
        failed[1]["code"] = -4001
        XCTAssertThrowsError(try MiIOProtocol.parseState(failed, deviceID: deviceID)) {
            XCTAssertEqual($0 as? MiIOProtocolError, .rpc(-4001))
        }
    }

    func testInfoRequiresTargetModelAndSafeFirmwareString() throws {
        XCTAssertEqual(try MiIOProtocol.validateInfo(["model": "xiaomi.light.bar2", "fw_ver": "1.1.3"]), "1.1.3")
        XCTAssertThrowsError(try MiIOProtocol.validateInfo(["model": "other.light", "fw_ver": "1"])) {
            XCTAssertEqual($0 as? MiIOProtocolError, .unsupportedDevice)
        }
        for firmware in ["", "bad\nfirmware", String(repeating: "x", count: 129), 113, NSNull()] as [Any] {
            XCTAssertThrowsError(try MiIOProtocol.validateInfo(["model": "xiaomi.light.bar2", "fw_ver": firmware]))
        }
    }

    private var token: Data { data(tokenHex) }

    private func data(_ hex: String) -> Data {
        let characters = Array(hex)
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    private func decode(_ packet: Data) throws -> Any {
        try MiIOProtocol.decodeResponse(packet, id: 42, token: token, deviceID: deviceID, timestamp: timestamp)
    }

    private func encode(_ method: String, _ params: [[String: Any]]) throws -> Data {
        try MiIOProtocol.encodeRequest(method: method, params: params, id: 42, token: token,
                                     deviceID: deviceID, timestamp: timestamp)
    }

    private func properties() -> [[String: Any]] {
        [(1, true as Any), (2, 80 as Any), (3, 4106 as Any), (4, 0 as Any)].map {
            ["did": String(deviceID), "siid": 2, "piid": $0.0, "code": 0, "value": $0.1]
        }
    }
}
