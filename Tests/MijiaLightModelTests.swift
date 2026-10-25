import XCTest

final class MijiaLightModelTests: XCTestCase {
    private final class Store: MijiaLightCredentialStoring {
        var saved: MijiaLightCredentials?
        var loads = 0
        var saves = 0
        var removals = 0
        func load() throws -> MijiaLightCredentials? { loads += 1; return saved }
        func save(_ credentials: MijiaLightCredentials) throws { saves += 1; saved = credentials }
        func remove() throws { removals += 1; saved = nil }
    }

    private final class Service: MijiaLightServicing {
        var reads = 0
        var writes = [MijiaLightProperty]()
        var fail = false
        var reading = MijiaLightReading(
            state: MijiaLightState(isOn: true, brightness: 100, colorTemperature: 3806, mode: 0),
            deviceID: 1234567890, firmware: "1.1.3")
        func read(_ credentials: MijiaLightCredentials) async throws -> MijiaLightReading {
            reads += 1
            if fail { throw MiIOProtocolError.unsupportedDevice }
            return reading
        }
        func set(_ property: MijiaLightProperty, using credentials: MijiaLightCredentials) async throws -> MijiaLightReading {
            writes.append(property)
            if fail { throw MiIOProtocolError.invalidResponse }
            let before = reading.state
            let after: MijiaLightState
            switch property {
            case .power(let value):
                after = MijiaLightState(isOn: value, brightness: before.brightness, colorTemperature: before.colorTemperature, mode: 0)
            case .brightness(let value):
                after = MijiaLightState(isOn: before.isOn, brightness: value, colorTemperature: before.colorTemperature, mode: 0)
            case .colorTemperature(let value):
                after = MijiaLightState(isOn: before.isOn, brightness: before.brightness, colorTemperature: value, mode: 0)
            }
            reading = MijiaLightReading(state: after, deviceID: reading.deviceID, firmware: reading.firmware)
            return reading
        }
    }

    private func credentials(_ host: String = "192.168.1.100") throws -> MijiaLightCredentials {
        try MijiaLightCredentials(host: host, tokenHex: "00112233445566778899aabbccddeeff", deviceID: 1234567890)
    }

    @MainActor func testInitializationNeverReadsOrWritesHardware() throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let model = MijiaLightModel(service: service, store: store)
        XCTAssertEqual(service.reads, 0)
        XCTAssertTrue(service.writes.isEmpty)
        XCTAssertNil(model.state)
        XCTAssertTrue(model.hasSavedCredentials)
        XCTAssertEqual(model.hostText, "192.168.1.100")
        XCTAssertEqual(model.tokenText, "")
        XCTAssertFalse(model.canControl)
    }

    @MainActor func testRefreshOnlyReadsAndEnablesExplicitControls() async throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let model = MijiaLightModel(service: service, store: store)
        model.refresh()
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.canControl)
        await model.waitForPendingOperation()
        XCTAssertEqual(service.reads, 1)
        XCTAssertTrue(service.writes.isEmpty)
        XCTAssertEqual(model.state, service.reading.state)
        XCTAssertTrue(model.canControl)
        XCTAssertFalse(model.busy)
    }

    @MainActor func testUnverifiedReplacementDoesNotOverwriteSavedCredentials() async throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let previous = store.saved
        let model = MijiaLightModel(service: service, store: store)
        model.hostText = "192.168.1.101"
        model.tokenText = "ffeeddccbbaa99887766554433221100"
        service.fail = true
        model.saveAndConnect()
        await model.waitForPendingOperation()
        XCTAssertEqual(store.saved, previous)
        XCTAssertEqual(store.saves, 0)
        XCTAssertNil(model.state)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(service.writes.isEmpty)
        XCTAssertFalse(model.detail.contains(model.tokenText))
    }

    @MainActor func testSavingPinsVerifiedIdentityAndClearsTokenField() async throws {
        let service = Service(), store = Store()
        let model = MijiaLightModel(service: service, store: store)
        model.hostText = "192.168.1.100"
        model.tokenText = "00112233445566778899aabbccddeeff"
        model.saveAndConnect()
        await model.waitForPendingOperation()
        XCTAssertEqual(store.saved, try credentials())
        XCTAssertEqual(store.saves, 1)
        XCTAssertEqual(model.tokenText, "")
        XCTAssertTrue(model.canControl)
        XCTAssertTrue(service.writes.isEmpty)
    }

    @MainActor func testEditingConnectionFieldsBlocksOldTargetWrites() async throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let model = MijiaLightModel(service: service, store: store)
        model.refresh()
        await model.waitForPendingOperation()
        model.hostText = "192.168.1.101"
        model.setPower(false)
        XCTAssertFalse(model.canControl)
        model.hostText = "192.168.1.100"
        model.tokenText = "another token"
        model.setBrightness(50)
        XCTAssertFalse(model.canControl)
        XCTAssertTrue(service.writes.isEmpty)
    }

    @MainActor func testFailedWriteDisablesControlsAndNeverRetries() async throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let model = MijiaLightModel(service: service, store: store)
        model.refresh()
        await model.waitForPendingOperation()
        service.fail = true
        model.setPower(false)
        await model.waitForPendingOperation()
        model.setPower(false)
        XCTAssertEqual(service.writes, [.power(false)])
        XCTAssertNil(model.state)
        XCTAssertFalse(model.canControl)
        XCTAssertNotNil(store.saved)
        service.fail = false
        model.refresh()
        await model.waitForPendingOperation()
        XCTAssertTrue(model.canControl)
        XCTAssertEqual(service.writes.count, 1)
    }

    @MainActor func testBusyGuardAndRangeChecksPreventExtraWrites() async throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let model = MijiaLightModel(service: service, store: store)
        model.refresh()
        await model.waitForPendingOperation()
        model.setBrightness(0)
        model.setColorTemperature(6501)
        XCTAssertTrue(service.writes.isEmpty)
        model.setBrightness(80)
        model.setBrightness(81)
        model.setColorTemperature(4000)
        model.forget()
        await model.waitForPendingOperation()
        XCTAssertEqual(service.writes, [.brightness(80)])
        XCTAssertEqual(store.removals, 0)
        XCTAssertEqual(model.state?.brightness, 80)
        model.forget()
        XCTAssertEqual(store.removals, 1)
        XCTAssertFalse(model.hasSavedCredentials)
        XCTAssertNil(model.state)
        model.setPower(true)
        XCTAssertEqual(service.writes.count, 1)
    }

    @MainActor func testVerificationAndPreviewModesNeverWriteHardware() async throws {
        let service = Service(), store = Store()
        store.saved = try credentials()
        let readOnly = MijiaLightModel(service: service, store: store, readOnly: true)
        readOnly.refresh()
        await readOnly.waitForPendingOperation()
        readOnly.setPower(false)
        readOnly.setBrightness(50)
        readOnly.setColorTemperature(3000)
        XCTAssertFalse(readOnly.canControl)
        XCTAssertTrue(service.writes.isEmpty)

        let loads = store.loads
        let preview = MijiaLightModel(service: service, store: store, preview: true)
        preview.setPower(false)
        preview.setBrightness(50)
        preview.setColorTemperature(3000)
        preview.refresh()
        preview.saveAndConnect()
        XCTAssertEqual(preview.state?.isOn, false)
        XCTAssertEqual(preview.state?.brightness, 50)
        XCTAssertEqual(preview.state?.colorTemperature, 3000)
        XCTAssertEqual(store.loads, loads)
        XCTAssertEqual(service.reads, 1)
        XCTAssertTrue(service.writes.isEmpty)
    }
}
