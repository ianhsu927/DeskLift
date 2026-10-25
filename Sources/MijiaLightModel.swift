import Foundation
import Combine

@MainActor
final class MijiaLightModel: ObservableObject {
    @Published var hostText = ""
    @Published var tokenText = ""
    @Published private(set) var state: MijiaLightState?
    @Published private(set) var busy = false
    @Published private(set) var status = "未配置"
    @Published private(set) var detail = "设置挂灯的局域网 IP 与 Token 后连接。"
    @Published private(set) var firmware = ""
    @Published private(set) var hasSavedCredentials = false

    private let service: MijiaLightServicing
    private let store: MijiaLightCredentialStoring
    private let preview: Bool
    private let readOnly: Bool
    private var credentials: MijiaLightCredentials?
    private var pending: Task<Void, Never>?

    var canControl: Bool {
        guard !busy, !readOnly, state != nil else { return false }
        if preview { return true }
        return hasSavedCredentials && credentials?.deviceID != nil &&
            hostText.trimmingCharacters(in: .whitespacesAndNewlines) == credentials?.host && tokenText.isEmpty
    }

    init(service: MijiaLightServicing = MijiaLightClient(),
         store: MijiaLightCredentialStoring = KeychainMijiaLightStore(),
         preview: Bool = false, readOnly: Bool = false) {
        self.service = service
        self.store = store
        self.preview = preview
        self.readOnly = readOnly
        if preview {
            hostText = "192.168.1.100"
            state = MijiaLightState(isOn: true, brightness: 70, colorTemperature: 4000, mode: 0)
            status = "预览"
            detail = "预览数据，操作不会连接设备。"
            firmware = "1.1.3"
            return
        }
        do {
            credentials = try store.load()
            hostText = credentials?.host ?? ""
            hasSavedCredentials = credentials != nil
            if hasSavedCredentials {
                status = "待刷新"
                detail = "打开挂灯面板后读取状态；灯光仅在你操作时改变。"
            }
        } catch {
            status = "凭据不可用"
            detail = "无法读取挂灯凭据，请解锁登录钥匙串后重新刷新。"
        }
        // Initializing, launching, reconnecting, or opening a window never writes.
    }

    func saveAndConnect() {
        guard !busy else { return }
        guard !preview else { detail = "预览模式不会保存凭据或连接设备。"; return }
        do {
            let entered = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = entered.isEmpty ? credentials?.tokenHex ?? "" : entered
            let candidate = try MijiaLightCredentials(
                host: hostText.trimmingCharacters(in: .whitespacesAndNewlines), tokenHex: token,
                deviceID: entered.isEmpty ? credentials?.deviceID : nil)
            perform(status: "正在连接…", updateFields: true) { [service, store] in
                let reading = try await service.read(candidate)
                let confirmed = try MijiaLightCredentials(host: candidate.host, tokenHex: candidate.tokenHex,
                                                          deviceID: reading.deviceID)
                // Keep the previous saved device until the new one is verified.
                try store.save(confirmed)
                return (reading, confirmed)
            }
        } catch {
            state = nil
            status = "设置无效"
            detail = "请输入有效的局域网 IPv4 地址和 32 位十六进制 Token。"
        }
    }

    func refresh() {
        guard !busy else { return }
        if preview { return }
        if credentials == nil {
            do {
                credentials = try store.load()
                hasSavedCredentials = credentials != nil
                hostText = credentials?.host ?? hostText
            } catch {
                status = "凭据不可用"
                detail = "无法读取挂灯凭据，请解锁登录钥匙串后重试。"
                return
            }
        }
        guard let saved = credentials else { return }
        perform(status: "正在读取…") { [service, store] in
            let reading = try await service.read(saved)
            let confirmed = try MijiaLightCredentials(host: saved.host, tokenHex: saved.tokenHex,
                                                      deviceID: reading.deviceID)
            if confirmed != saved { try store.save(confirmed) }
            return (reading, confirmed)
        }
    }

    func setPower(_ on: Bool) { write(.power(on)) }
    func setBrightness(_ value: Int) {
        guard (1...100).contains(value) else { return }
        write(.brightness(value))
    }
    func setColorTemperature(_ value: Int) {
        guard (2700...6500).contains(value) else { return }
        write(.colorTemperature(value))
    }

    private func write(_ property: MijiaLightProperty) {
        guard canControl else { return }
        if preview {
            guard let current = state else { return }
            switch property {
            case .power(let value):
                state = MijiaLightState(isOn: value, brightness: current.brightness,
                                       colorTemperature: current.colorTemperature, mode: current.mode)
            case .brightness(let value):
                state = MijiaLightState(isOn: current.isOn, brightness: value,
                                       colorTemperature: current.colorTemperature, mode: 0)
            case .colorTemperature(let value):
                state = MijiaLightState(isOn: current.isOn, brightness: current.brightness,
                                       colorTemperature: value, mode: 0)
            }
            return
        }
        guard let saved = credentials else { return }
        perform(status: "正在更新…", didWrite: true) { [service] in
            let reading = try await service.set(property, using: saved)
            return (reading, saved)
        }
    }

    private func perform(status nextStatus: String, updateFields: Bool = false, didWrite: Bool = false,
                         operation: @escaping () async throws -> (MijiaLightReading, MijiaLightCredentials)) {
        busy = true
        status = nextStatus
        pending = Task { [weak self] in
            do {
                let (reading, confirmed) = try await operation()
                guard let self else { return }
                self.credentials = confirmed
                self.hasSavedCredentials = true
                self.state = reading.state
                self.firmware = reading.firmware
                self.status = "已连接"
                self.detail = self.readOnly ? "只读验证模式，灯光操作已禁用。" : "局域网直连 · 状态已读回确认。"
                if updateFields {
                    self.hostText = confirmed.host
                    self.tokenText = ""
                }
                self.busy = false
            } catch {
                guard let self else { return }
                self.state = nil
                self.status = "未能确认状态"
                if error is MijiaLightStoreError {
                    self.detail = "无法保存凭据，请检查登录钥匙串访问权限。"
                } else {
                    let reason = (error as? MiIOProtocolError)?.errorDescription
                        ?? (error as? MijiaLightClientError)?.errorDescription
                        ?? "请检查挂灯网络、IP 与 Token，然后刷新。"
                    self.detail = reason + (didWrite ? " 操作未自动重试；灯光可能已改变，以刷新读数为准。" : "")
                }
                self.busy = false
            }
        }
    }

    func forget() {
        guard !busy else { return }
        if !preview {
            do { try store.remove() }
            catch {
                detail = "无法移除钥匙串中的挂灯凭据，请解锁登录钥匙串后重试。"
                return
            }
        }
        credentials = nil
        hasSavedCredentials = false
        state = nil
        firmware = ""
        hostText = ""
        tokenText = ""
        status = "未配置"
        detail = "已移除本机挂灯凭据。"
    }

    // Deterministic test synchronization without starting timers or networking.
    func waitForPendingOperation() async { await pending?.value }
}
