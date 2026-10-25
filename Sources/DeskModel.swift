import AppKit
import Combine
import CoreBluetooth

struct NearbyDesk: Identifiable {
    let id: UUID
    var name: String
    var rssi: Int
    var connectable: Bool
}

struct ControllerMemoryRow {
    let slot: Int
    let heightText: String
    let detail: String
    let isLoaded: Bool
    let isEmpty: Bool

    static var unread: [ControllerMemoryRow] {
        (0..<4).map { ControllerMemoryRow(slot: $0, heightText: "未读取", detail: "", isLoaded: false, isEmpty: false) }
    }
}

final class DeskModel: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var devices: [NearbyDesk] = []
    @Published var status = "尚未连接"
    @Published var detail = "按住 DPI1C 底部连接键约 2 秒，然后搜索桌子。"
    @Published var scanning = false
    @Published var connecting = false
    @Published var ready = false
    @Published var deskName = "你的升降桌"
    @Published var rawHeight: Int?
    @Published var baseHeight: Double?
    @Published var speed = 0.0
    @Published var activeTarget: Int?
    @Published var targetText = ""
    @Published var presets: [Int?] = [nil, nil]
    @Published var logs: [String] = []
    @Published var showDiagnostics = false
    @Published private(set) var controllerMemoryRows = ControllerMemoryRow.unread
    @Published private(set) var controllerMemoryCustomNames = Array(repeating: "", count: 4)
    private let controllerMemoryNameStore = ControllerMemoryNameStore()
    private var controllerMemoryNamingDeviceID: UUID?
    @Published var controllerMemoryDrafts = Array(repeating: "", count: 4)
    @Published private(set) var controllerMemoryBusy = false
    @Published private(set) var controllerMemoryStatus = "未读取"
    private var controllerMemoryCache: [ControllerMemoryProtocol.Reply?] = Array(repeating: nil, count: 4)
    private var controllerMemoryAutoDrafts = Array(repeating: "", count: 4)
    private var controllerMemoryCacheSession: UUID?
    private var controllerMemoryCacheBase: Double?
    private var controllerMemoryOperation: ControllerMemoryOperation?
    private var controllerMemoryRequiresReconnect = false
    private var controllerMemoryHasUsedProtocol = false
    private var controllerMemoryDidSend = false
    private var controllerMemoryOperationSession: UUID?
    private var controllerMemoryOperationBase: Double?
    private var controllerMemoryOperationInitialRaw: Int?
    private var controllerMemoryOperationLocalPresets: [Int?] = []
    private var controllerMemoryWriteTarget: DeskCommandTarget?
    private var controllerMemoryWriteSlot: Int?
    private var controllerMemoryWriteAuthorizedAt: TimeInterval?
    private enum InitialConfigRead: Equatable { case base, name }
    private var initialConfigQueue: [InitialConfigRead] = []
    private var initialConfigPending: InitialConfigRead?
    private var initialConfigDeadline: TimeInterval?
    private var initialConfigQueuedAt: TimeInterval?
    private var lastInitialConfigReply = -Double.infinity
    let memoryVerificationOnly: Bool
    @Published private(set) var memoryVerificationRunning = false
    @Published private(set) var memoryVerificationSummary = "尚未读取控制器记忆"
    private var memoryReadSession: ControllerMemoryReadSession?
    private var memoryReadQuarantined = false
    private var memoryReadConnectionID: UUID?
    private var memoryReadBase: Double?
    private var memoryReadInitialRaw: Int?
    private var memoryReadOriginalPresets: [Int?] = []
    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var peripheral: CBPeripheral?
    private var chars: [String: CBCharacteristic] = [:]
    private var notified = Set<String>()
    private var pendingServices = 0
    private var tick: Timer?
    private var scanTimeout: Timer?
    private var connectTimeout: Timer?
    private var lastFeedback = -Double.infinity
    private var lastRead = 0.0
    private var lastHeartbeat = 0.0
    private var lastQuery = 0.0
    private var motion: MotionGuard?
    private(set) var motionID: UUID?
    private(set) var connectionSessionID = UUID()
    struct MotionResult {
        let id: UUID
        let reachedTarget: Bool
        let reason: String
    }
    private(set) var lastMotionResult: MotionResult?
    private var stopPending = false
    private var cooldownUntil = 0.0
    private var observers: [NSObjectProtocol] = []
    private let preview: Bool
    private let clock = { ProcessInfo.processInfo.systemUptime }
    var height: Double? {
        guard !controllerMemoryRequiresReconnect, let rawHeight, let baseHeight else { return nil }
        return baseHeight + Double(rawHeight) / 100
    }
    var canMove: Bool { !memoryVerificationOnly && !controllerMemoryBusy && !controllerMemoryRequiresReconnect && initialConfigIsIdle && ready && height != nil && abs(speed) < 0.1 && motion == nil && !stopPending && clock() >= cooldownUntil }
    private var initialConfigIsIdle: Bool { initialConfigPending == nil && initialConfigQueue.isEmpty }
    var canRefreshControllerMemory: Bool {
        !memoryVerificationOnly && !controllerMemoryBusy && !controllerMemoryRequiresReconnect && initialConfigIsIdle &&
        ready && height?.isFinite == true && speed.isFinite && abs(speed) < 0.1 && motion == nil &&
        !stopPending && clock() >= cooldownUntil && clock() - lastFeedback <= 1.5 && clock() - lastInitialConfigReply >= 0.75
    }
    var canWriteControllerMemory: Bool {
        canRefreshControllerMemory && controllerMemoryCacheSession == connectionSessionID && controllerMemoryCacheBase == baseHeight &&
        controllerMemoryCache.allSatisfy { $0?.isRecognizedStorageReply == true }
    }
    var canCancelControllerMemory: Bool { controllerMemoryBusy }
    var canRenameControllerMemory: Bool {
        !memoryVerificationOnly && controllerMemoryNamingDeviceID != nil && !connecting && !controllerMemoryBusy && !isActive
    }
    func controllerMemoryName(_ slot: Int) -> String {
        guard controllerMemoryCustomNames.indices.contains(slot) else { return "档位" }
        let name = controllerMemoryCustomNames[slot]
        return name.isEmpty ? "档位 \(slot + 1)" : name
    }
    func controllerMemoryHasCustomName(_ slot: Int) -> Bool {
        guard controllerMemoryCustomNames.indices.contains(slot) else { return false }
        let name = controllerMemoryCustomNames[slot]
        return !name.isEmpty && name != "档位 \(slot + 1)"
    }
    func controllerMemorySlotTitle(_ slot: Int) -> String {
        controllerMemoryHasCustomName(slot) ? "\(controllerMemoryName(slot))（档位 \(slot + 1)）" : controllerMemoryName(slot)
    }
    var canVerifyControllerMemory: Bool {
        memoryVerificationOnly && initialConfigIsIdle && ready && height != nil && abs(speed) < 0.1 && motion == nil &&
        !stopPending && !memoryReadQuarantined && clock() - lastFeedback <= 1.5 && clock() - lastInitialConfigReply >= 0.75
    }
    var isActive: Bool { activeTarget != nil }
    var heightText: String { height.map { String(format: "%.1f", $0) } ?? "—" }
    var rangeText: String {
        if controllerMemoryRequiresReconnect { return "配置状态尚未确认，请断开并重新连接。" }
        guard let b = baseHeight else { return "等待读取桌子高度" }
        return String(format: "本版本支持范围 %.1f–%.1f cm；桌子自身限位仍然生效", b, b + 65)
    }
    init(preview: Bool = false, memoryVerificationOnly: Bool = false) {
        self.preview = preview
        self.memoryVerificationOnly = memoryVerificationOnly
        super.init()
        if preview {
            status = "界面预览 · 未连接硬件"
            detail = "预览不扫描蓝牙，也不会向桌子发送指令。"
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.motion != nil { self?.stop("应用失去焦点，已停止") }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.disconnect() })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.disconnect() })
        log("DeskLift 1.0 · 原生 CoreBluetooth · DPI1C")
        if memoryVerificationOnly {
            detail = "只读记忆验证模式：禁用升降与保存，连接后从诊断窗口读取。"
            log("只读记忆验证模式 · 禁止目标高度、保存、删除及校准写入")
        }
    }
    func log(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        logs.append("\(f.string(from: Date()))  \(text)")
        if logs.count > 250 { logs.removeFirst(logs.count - 250) }
    }
    func scan() {
        guard !memoryVerificationOnly || !memoryReadQuarantined else {
            detail = "只读验证会话已结束，请退出并重新打开应用后再连接。"
            return
        }
        guard !preview, !connecting, peripheral == nil else { return }
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: true])
            return
        }
        guard central.state == .poweredOn else { updateBluetoothState(); return }
        devices = []; peripherals = [:]
        scanning = true; status = "正在搜索"; detail = "保持桌子处于配对状态，并关闭其他占用连接的应用。"
        // Scan all services: some firmware advertises only the name while pairing.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        log("开始搜索附近 LINAK / DESK 蓝牙广播（20 秒）")
        scanTimeout?.invalidate()
        scanTimeout = Timer.scheduledTimer(withTimeInterval: 20, repeats: false) { [weak self] _ in self?.endScan() }
    }
    func endScan() {
        central?.stopScan(); scanTimeout?.invalidate(); scanning = false
        if peripheral == nil {
            status = devices.isEmpty ? "未发现桌子" : "请选择桌子"
            detail = devices.isEmpty ? "请检查桌子供电、配对模式，以及系统设置中的蓝牙权限。" : "名称仅用于发现；连接后会检查 DPI1C 所需的通信特征。"
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            log("蓝牙已开启 · 授权 \(CBManager.authorization.rawValue)")
            if peripheral == nil { scan() }
        }
        else {
            clearSession()
            updateBluetoothState()
        }
    }
    private func updateBluetoothState() {
        switch central?.state {
        case .unauthorized:
            status = "需要蓝牙权限"; detail = "前往 系统设置 → 隐私与安全性 → 蓝牙，允许 DeskLift。"
        case .poweredOff:
            status = "蓝牙已关闭"; detail = "请在 Mac 系统设置中打开蓝牙，再搜索桌子。"
        case .unsupported:
            status = "蓝牙不可用"; detail = "此 Mac 当前无法使用低功耗蓝牙。"
        default:
            status = "蓝牙正在准备"; detail = "请稍候，再点击搜索桌子。"
        }
        log("\(status) · 蓝牙状态 \(central?.state.rawValue ?? -1) · 授权 \(CBManager.authorization.rawValue)")
    }
    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
        let name = (a[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let services = a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let manufacturer = a[CBAdvertisementDataManufacturerDataKey] as? Data
        let maker = manufacturer.map { Array($0.prefix(2)) == [0xa4, 0x00] } ?? false
        let upper = name.uppercased()
        guard upper.contains("DESK") || upper.contains("LINAK") || maker || services.contains(CBUUID(string: DPI.service)) else { return }
        peripherals[p.identifier] = p
        let connectable = (a[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue ?? true
        let d = NearbyDesk(id: p.identifier, name: name.isEmpty ? "LINAK 蓝牙设备" : name, rssi: rssi.intValue, connectable: connectable)
        if let i = devices.firstIndex(where: { $0.id == p.identifier }) {
            if devices[i].connectable != connectable { log("\(d.name) 可连接状态：\(connectable)") }
            devices[i] = d
        }
        else { devices.append(d); log("发现 \(d.name) · 可连接：\(connectable)") }
    }
    func connect(_ id: UUID) {
        guard !memoryVerificationOnly || !memoryReadQuarantined else {
            detail = "只读验证会话已结束，请退出并重新打开应用后再连接。"
            return
        }
        guard !connecting, peripheral == nil, let p = peripherals[id], devices.first(where: { $0.id == id })?.connectable == true else { return }
        endScan(); clearSession(); peripheral = p; p.delegate = self
        controllerMemoryNamingDeviceID = id
        controllerMemoryCustomNames = controllerMemoryNameStore.names(for: id)
        connecting = true; deskName = devices.first(where: { $0.id == id })?.name ?? "LINAK 桌子"
        status = "正在连接"; detail = "如 macOS 提示蓝牙配对，请在系统提示中完成配对。"
        presets = (UserDefaults.standard.array(forKey: "presets.\(id)") as? [Int] ?? [-1, -1]).prefix(2).map { $0 < 0 ? nil : $0 }
        while presets.count < 2 { presets.append(nil) }
        central.connect(p, options: nil)
        log("连接 \(deskName) · 系统设备状态 \(p.state.rawValue)")
        connectTimeout = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            guard let self, !self.ready else { return }
            self.fail("连接或读取超时；请重新进入配对模式，并退出手机上的连接。")
        }
    }
    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p == peripheral else { return }
        log("已建立蓝牙连接，正在检查通信服务")
        p.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        fail("连接失败：\(error?.localizedDescription ?? "请重试配对")")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        guard p == peripheral else { return }
        clearSession(); status = "连接已断开"
        detail = error?.localizedDescription ?? "点击搜索桌子重新连接；不会自动恢复升降。"
        log("连接已断开；所有运动任务已取消")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p == peripheral else { return }
        if let error { fail("读取服务失败：\(error.localizedDescription)"); return }
        let services = p.services ?? []; pendingServices = services.count
        guard !services.isEmpty else { fail("设备没有可用通信服务"); return }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        guard p == peripheral else { return }
        if let error { fail("读取通信特征失败：\(error.localizedDescription)"); return }
        for c in s.characteristics ?? [] {
            let id = c.uuid.uuidString.lowercased()
            if [DPI.control, DPI.config, DPI.status, DPI.move].contains(id) {
                chars[id] = c
                log("发现通信特征 \(String(id.prefix(8))) · 属性 \(c.properties.rawValue)")
            }
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        guard [DPI.control, DPI.config, DPI.status, DPI.move].allSatisfy({ chars[$0] != nil }) else {
            fail("通信特征不完整，此设备可能不是兼容的 DPI1C。")
            return
        }
        guard [DPI.control, DPI.config, DPI.move].allSatisfy({ chars[$0]!.properties.contains(.writeWithoutResponse) }) else {
            fail("此固件不支持预期的蓝牙写入方式，暂不开放升降。")
            return
        }
        for id in [DPI.status, DPI.config] {
            let c = chars[id]!
            guard c.properties.contains(.notify) || c.properties.contains(.indicate) else { fail("设备不支持所需高度通知"); return }
            p.setNotifyValue(true, for: c)
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        guard p == peripheral else { return }
        if let error { fail("订阅失败：\(error.localizedDescription)。请在系统提示中完成配对。"); return }
        guard c.isNotifying else { fail("蓝牙通知意外关闭"); return }
        notified.insert(c.uuid.uuidString.lowercased())
        if notified.contains(DPI.status) && notified.contains(DPI.config) && tick == nil {
            status = "正在读取高度"; detail = "正在读取桌子实际高度及高度基准，完成后开放控制。"
            queryConfig(); readStatus()
            tick = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.pulse() }
            RunLoop.main.add(tick!, forMode: .common)
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        guard p == peripheral else { return }
        if let error { fail("读取失败：\(error.localizedDescription)"); return }
        guard let data = c.value else { return }
        let id = c.uuid.uuidString.lowercased()
        if id == DPI.status {
            guard receiveHeightFeedback(data) else { return }
        } else if id == DPI.config {
            guard receiveControllerConfiguration(data) else { return }
        }
        if !ready, height != nil {
            ready = true; connecting = false; connectTimeout?.invalidate()
            status = "已连接"
            detail = memoryVerificationOnly ? "只读验证模式，升降与保存已禁用。请打开连接诊断，读取控制器记忆。" : "按住按钮升降，松开即停止。首次使用请小幅测试。"
            targetText = heightText
            log("就绪：高度和基准均已从桌子读取")
        }
    }
    // Decode entry points are shared by the BLE delegate and packet-replay
    // tests. They do not create a Bluetooth manager or establish a connection.
    @discardableResult func receiveHeightFeedback(_ data: Data) -> Bool {
        guard let value = DPI.status(data) else {
            log("收到无法识别的高度数据：\(data.map { String(format: "%02x", $0) }.joined())")
            if motion != nil { stop("高度数据异常，已停止") }
            if controllerMemoryBusy { abortControllerMemoryForUntrustedConfiguration("高度数据异常") }
            return false
        }
        rawHeight = value.raw; speed = value.speed; lastFeedback = clock()
        return true
    }
    @discardableResult func receiveControllerConfiguration(_ data: Data) -> Bool {
        if memoryReadQuarantined {
            if memoryVerificationRunning {
                memoryReadSession?.receive(data, at: clock())
                updateMemoryVerification()
            } else {
                log("隔离验证后的配置通知：\(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
            }
            return false
        }
        if controllerMemoryRequiresReconnect {
            log("已隔离未确认的配置回复")
            return false
        }
        if controllerMemoryBusy {
            if data == Data([1, 3, 1, 1, 0]), controllerMemoryOperation?.acceptsEmptySlotOneReply != true {
                abortControllerMemoryForUntrustedConfiguration("收到无法区分记忆与校准的回复")
                return false
            }
            if let base = DPI.base(data), base != controllerMemoryOperationBase,
               data != Data([1, 3, 1, 1, 0]) {
                abortControllerMemoryForUntrustedConfiguration("读取期间高度基准已改变")
                return false
            }
            controllerMemoryOperation?.receive(data, at: clock())
            updateControllerMemoryOperation()
            return false
        }
        receiveInitialOrUnsolicitedConfig(data)
        return true
    }
    private func abortControllerMemoryForUntrustedConfiguration(_ reason: String) {
        controllerMemoryRequiresReconnect = true
        invalidateControllerMemoryCache(message: "\(reason)，请重新连接。")
        controllerMemoryOperation?.cancel(reason: reason, at: clock())
        finishControllerMemoryOperation()
    }
    private func queryConfig() {
        guard peripheral?.state == .connected, !memoryReadQuarantined, !controllerMemoryBusy,
              !controllerMemoryRequiresReconnect, initialConfigIsIdle else { return }
        initialConfigQueue = [.base, .name]
        initialConfigQueuedAt = clock()
        lastQuery = clock()
        pumpInitialConfiguration(at: clock())
    }
    private func pumpInitialConfiguration(at now: TimeInterval) {
        guard !memoryReadQuarantined, !controllerMemoryBusy, !controllerMemoryRequiresReconnect else { return }
        if let pending = initialConfigPending, let deadline = initialConfigDeadline, now >= deadline {
            initialConfigPending = nil; initialConfigDeadline = nil
            lastInitialConfigReply = now
            if case .base = pending { fail("读取高度基准超时，请重新连接。"); return }
            log("桌子名称未返回，保留蓝牙广播名称")
            initialConfigQueuedAt = now
        }
        guard initialConfigPending == nil, let request = initialConfigQueue.first else { return }
        if let since = initialConfigQueuedAt, now - since >= 3 {
            if case .base = request { fail("无法发送高度基准查询，请重新连接。"); return }
            initialConfigQueue.removeFirst(); initialConfigQueuedAt = now
            lastInitialConfigReply = now
            return
        }
        let command = request == .base ? DPI.readBase : DPI.readName
        if write(command, to: DPI.config) {
            initialConfigQueue.removeFirst()
            initialConfigPending = request
            initialConfigDeadline = now + 3
            initialConfigQueuedAt = nil
        }
    }
    private func receiveInitialOrUnsolicitedConfig(_ data: Data) {
        let bytes = Array(data)
        let memoryShaped = (bytes.count == 7 && bytes[0] == 1 && bytes[1] == 5 && bytes[2] <= 3) ||
            (bytes.count == 5 && bytes[0] == 1 && bytes[1] == 3 && bytes[2] <= 3 && bytes[3] == 1 && bytes[4] == 0)
        // The slot-1 empty frame is also a syntactically valid 0.01 cm base.
        // After memory I/O, never accept that ambiguity as new calibration.
        if controllerMemoryHasUsedProtocol && memoryShaped {
            if DPI.base(data) != nil {
                controllerMemoryRequiresReconnect = true
                invalidateControllerMemoryCache(message: "收到歧义配置回复，请断开并重新连接。")
                stop("配置回复无法区分记忆与校准，已停止并要求重新连接")
            } else { log("忽略没有待处理请求的记忆回复") }
            return
        }
        if initialConfigPending == .base {
            guard let base = DPI.base(data) else { return }
            acceptCalibration(base)
            initialConfigPending = nil; initialConfigDeadline = nil
            initialConfigQueuedAt = clock(); lastInitialConfigReply = clock()
        } else if initialConfigPending == .name {
            guard let name = Self.configName(data) else {
                if let base = DPI.base(data) { acceptCalibration(base) }
                return
            }
            deskName = name
            initialConfigPending = nil; initialConfigDeadline = nil
            initialConfigQueuedAt = clock(); lastInitialConfigReply = clock()
        } else if let base = DPI.base(data) {
            acceptCalibration(base)
        } else if let name = Self.configName(data) {
            deskName = name
        }
    }
    private static func configName(_ data: Data) -> String? {
        let b = Array(data)
        guard b.count > 2, b.count <= 14, b[0] == 1, Int(b[1]) == b.count - 2,
              b.dropFirst(2).allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(data: data.dropFirst(2), encoding: .ascii)
    }
    private func acceptCalibration(_ base: Double) {
        if let old = baseHeight, old != base {
            if motion != nil { stop("高度基准改变，已停止") }
            invalidateControllerMemoryCache(message: "高度基准已改变，请重新读取控制器记忆。")
        }
        baseHeight = base
        log(String(format: "读取高度基准 %.2f cm", base))
    }
    private func readStatus() {
        if let p = peripheral, let c = chars[DPI.status], c.properties.contains(.read) { p.readValue(for: c) }
        lastRead = clock()
    }
    @discardableResult private func write(_ data: Data, to id: String) -> Bool {
        if id == DPI.config {
            let read = data == DPI.readBase || data == DPI.readName || ControllerMemoryProtocol.isReadCommand(data)
            let authorizedSave = ControllerMemoryProtocol.isSaveCommand(data) && controllerMemorySaveIsAuthorized(data)
            guard read || authorizedSave else { return false }
        }
        if memoryVerificationOnly {
            let permittedRead = id == DPI.config && (data == DPI.readBase || data == DPI.readName || ControllerMemoryProtocol.isReadCommand(data))
            let permittedStop = id == DPI.control && data == DPI.stop
            guard permittedRead || permittedStop else { return false }
        }
        guard let p = peripheral, p.state == .connected, let c = chars[id], p.canSendWriteWithoutResponse else { return false }
        if memoryVerificationOnly {
            log("只读验证 TX \(id.prefix(8))：\(data.map { String(format: "%02X", $0) }.joined(separator: " "))")
        }
        p.writeValue(data, for: c, type: .withoutResponse)
        return true
    }
    func hold(up: Bool) { start(raw: up ? DPI.maxRaw : 0) }
    func goToTarget() {
        guard let b = baseHeight, let cm = Double(targetText.replacingOccurrences(of: ",", with: ".")), let raw = DPI.raw(cm: cm, base: b) else {
            detail = "请输入支持范围内的有效高度。"; return
        }
        start(raw: raw)
    }
    enum StartResult { case started(UUID), alreadyThere, unavailable, staleFeedback }
    @discardableResult private func start(raw: Int) -> StartResult {
        guard canMove, let current = rawHeight, DPI.target(raw) != nil else { return .unavailable }
        guard clock() - lastFeedback <= 1.5 else {
            readStatus(); detail = "高度反馈尚未更新，请稍候再试。"; return .staleFeedback
        }
        guard abs(raw - current) > 15 else { detail = "已经处于这个高度附近。"; return .alreadyThere }
        let now = clock()
        let id = UUID()
        motionID = id
        motion = MotionGuard(target: raw, started: now, lastProgress: now, progressRaw: current)
        activeTarget = raw; status = "正在升降"; detail = "随时按停止或 Esc；切换应用也会取消本次升降。"
        log(String(format: "开始升降 → %.1f cm", (baseHeight ?? 0) + Double(raw) / 100))
        pulse()
        return .started(id)
    }
    func stop(_ reason: String = "已停止") {
        if controllerMemoryBusy { cancelControllerMemoryOperation(reason: reason) }
        if memoryVerificationRunning { finishMemoryVerification(failure: "验证已取消：\(reason)") }
        if let id = motionID {
            lastMotionResult = MotionResult(id: id, reachedTarget: reason == "已到达目标高度", reason: reason)
        }
        motion = nil; motionID = nil; activeTarget = nil
        guard peripheral?.state == .connected else { return }
        stopPending = true
        cooldownUntil = clock() + 0.8
        status = ready ? "已连接" : status; detail = reason; log(reason)
        // A stop has priority over future movement writes. Never queue a stale target.
        flushStop()
    }
    private func flushStop() {
        guard stopPending else { return }
        if write(DPI.stop, to: DPI.control) {
            stopPending = false
            let p = peripheral
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.peripheral == p, self.motion == nil else { return }
                _ = self.write(DPI.heartbeat, to: DPI.move)
            }
        }
    }
    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard p == peripheral else { return }; flushStop()
    }
    private func pulse() {
        let now = clock()
        if stopPending { flushStop(); return }
        if now - lastRead > 1 { readStatus() }
        pumpInitialConfiguration(at: now)
        if !ready && now - lastQuery > 2 { queryConfig() }
        if memoryVerificationOnly {
            pumpMemoryVerification(at: now)
            return
        }
        if controllerMemoryBusy {
            pumpControllerMemoryOperation(at: now)
            return
        }
        if var guardState = motion, let raw = rawHeight {
            if let why = guardState.evaluate(raw: raw, speed: speed, feedbackAt: lastFeedback, now: now) { stop(why); return }
            motion = guardState
            if let data = DPI.target(guardState.target) { _ = write(data, to: DPI.move) }
        } else if ready && now - lastHeartbeat > 30 {
            _ = write(DPI.heartbeat, to: DPI.move); lastHeartbeat = now
        }
    }
    func savePreset(_ slot: Int) {
        guard canMove, let raw = rawHeight, clock() - lastFeedback < 2, (0..<2).contains(slot) else { return }
        presets[slot] = raw
        if let id = peripheral?.identifier { UserDefaults.standard.set(presets.map { $0 ?? -1 }, forKey: "presets.\(id)") }
        detail = "已将当前高度保存为\(slot == 0 ? "坐姿" : "站姿")，仅保存在这台 Mac。"
        log(detail)
    }
    func recallPreset(_ slot: Int) { if (0..<2).contains(slot), let raw = presets[slot] { start(raw: raw) } }
    // App Intents use the same calibrated session and movement guard as the UI.
    // Never retain a command for a future connection or create a second BLE model.
    private var commandState: DeskCommandState {
        DeskCommandState(ready: ready, rawHeight: rawHeight, baseHeight: baseHeight,
                         speed: speed, canMove: canMove, feedbackAge: clock() - lastFeedback)
    }
    func shortcutHeight() throws -> Double {
        guard !controllerMemoryRequiresReconnect else { throw DeskCommandError.unavailable }
        do { return try commandState.currentHeight() }
        catch {
            if ready { readStatus() }
            throw error
        }
    }
    func shortcutTarget(height cm: Double) throws -> DeskCommandTarget {
        let state = commandState
        let raw = try state.target(height: cm)
        return try DeskCommandTarget(raw: raw, state: state, sessionID: connectionSessionID)
    }
    func shortcutPresetTarget(_ slot: Int) throws -> DeskCommandTarget {
        guard presets.indices.contains(slot) else { throw DeskCommandError.presetMissing }
        let state = commandState
        let raw = try state.target(preset: presets[slot])
        return try DeskCommandTarget(raw: raw, state: state, sessionID: connectionSessionID)
    }
    func shortcutMove(to target: DeskCommandTarget, presetSlot: Int? = nil) throws -> UUID? {
        let raw = try target.validatedRaw(in: commandState, sessionID: connectionSessionID)
        if let presetSlot {
            guard presets.indices.contains(presetSlot) else { throw DeskCommandError.presetChanged }
            try target.validatePreset(presets[presetSlot])
        }
        // Revalidate the raw target immediately before starting. Avoid a second
        // cm→raw conversion at decimal calibration/travel boundaries.
        switch start(raw: raw) {
        case .started(let id): return id
        case .alreadyThere: return nil
        case .staleFeedback: throw DeskCommandError.staleFeedback
        case .unavailable: throw DeskCommandError.busy
        }
    }
    func shortcutSavePreset(_ slot: Int) throws -> Double {
        guard presets.indices.contains(slot) else { throw DeskCommandError.presetMissing }
        let cm = try commandState.currentHeight()
        _ = try commandState.target(preset: rawHeight)
        savePreset(slot)
        return cm
    }
    func shortcutStop() -> Bool {
        let connected = peripheral?.state == .connected
        stop("Siri / 快捷指令已请求停止")
        return connected
    }
    func presetLabel(_ slot: Int) -> String {
        guard let b = baseHeight, let raw = presets[slot] else { return "尚未保存" }
        return String(format: "%.1f cm", b + Double(raw) / 100)
    }
    func refreshControllerMemory() {
        guard canRefreshControllerMemory, let base = baseHeight else {
            controllerMemoryStatus = controllerMemoryRequiresReconnect ? "请先断开并重新连接，再刷新内部记忆。" : "请先连接桌子，等待静止且高度反馈更新。"
            return
        }
        controllerMemoryWriteTarget = nil
        controllerMemoryWriteSlot = nil
        controllerMemoryWriteAuthorizedAt = nil
        beginControllerMemoryOperation(.readAll, base: base)
    }
    func renameControllerMemory(_ slot: Int) {
        guard canRenameControllerMemory, (0..<4).contains(slot), let deviceID = controllerMemoryNamingDeviceID else { return }
        let field = NSTextField(string: controllerMemoryCustomNames[slot])
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.placeholderString = "档位 \(slot + 1)"
        field.usesSingleLineMode = true
        field.setAccessibilityLabel("档位 \(slot + 1) 的名称")
        let alert = NSAlert()
        alert.messageText = "重命名档位 \(slot + 1)"
        alert.informativeText = "最多 24 个字符，留空恢复默认。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存名称")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard canRenameControllerMemory, controllerMemoryNamingDeviceID == deviceID else {
            controllerMemoryStatus = "桌子连接已改变，未保存名称。"
            return
        }
        guard controllerMemoryNameStore.setName(field.stringValue, slot: slot, for: deviceID) else { return }
        controllerMemoryCustomNames = controllerMemoryNameStore.names(for: deviceID)
        if !controllerMemoryRequiresReconnect { controllerMemoryStatus = "名称已保存" }
        log("已更新\(controllerMemorySlotTitle(slot))的本地名称")
    }
    func requestControllerMemoryWrite(slot: Int, heightText: String?) {
        guard canWriteControllerMemory, controllerMemoryCache.indices.contains(slot),
              let previous = controllerMemoryCache[slot], previous.isRecognizedStorageReply,
              let base = baseHeight, let currentRaw = rawHeight else {
            controllerMemoryStatus = "请先刷新，取得当前设备的四组记忆后再写入。"
            return
        }
        let target: DeskCommandTarget
        do {
            if let text = heightText {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
                guard let cm = Double(trimmed) else { throw DeskCommandError.invalidHeight }
                target = try shortcutTarget(height: cm)
            } else {
                target = try DeskCommandTarget(raw: currentRaw, state: commandState, sessionID: connectionSessionID)
            }
        } catch {
            controllerMemoryStatus = error.localizedDescription
            return
        }
        let oldValue = previous.confirmedRaw.map { String(format: "%.2f cm", base + Double($0) / 100) } ?? "空档位"
        let newValue = String(format: "%.2f cm", target.height)
        let slotTitle = controllerMemorySlotTitle(slot)
        let alert = NSAlert()
        alert.messageText = "写入\(slotTitle)？"
        alert.informativeText = "原值：\(oldValue)\n新值：\(newValue)"
        alert.addButton(withTitle: "写入\(slotTitle)")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // NSAlert runs a nested event loop. Revalidate after consent, not just
        // before showing it, and never keep this consent across reconnection.
        guard canWriteControllerMemory, target.sessionID == connectionSessionID, target.baseHeight == baseHeight,
              let latestRaw = rawHeight, abs(latestRaw - currentRaw) < 15,
              controllerMemoryCache[slot]?.state == previous.state else {
            controllerMemoryStatus = "确认期间连接、校准、位置或档位已变化，请刷新后重新确认。"
            return
        }
        controllerMemoryWriteTarget = target
        controllerMemoryWriteSlot = slot
        controllerMemoryWriteAuthorizedAt = clock()
        beginControllerMemoryOperation(.save(slot: slot, raw: target.raw, expectedPrevious: previous.state), base: base)
    }
    private func beginControllerMemoryOperation(_ kind: ControllerMemoryOperation.Kind, base: Double) {
        controllerMemoryOperationSession = connectionSessionID
        controllerMemoryOperationBase = base
        controllerMemoryOperationInitialRaw = rawHeight
        controllerMemoryOperationLocalPresets = presets
        controllerMemoryDidSend = false
        controllerMemoryOperation = ControllerMemoryOperation(kind: kind, expectedBase: base, now: clock())
        controllerMemoryBusy = true
        controllerMemoryStatus = controllerMemoryWriteSlot == nil ? "读取中…" : "写入中…"
        detail = controllerMemoryStatus
        log("开始控制器记忆操作 · 会话 \(connectionSessionID) · \(controllerMemoryWriteSlot.map { "写入档位 \($0 + 1)" } ?? "读取四槽")")
    }
    func cancelControllerMemoryOperation() {
        cancelControllerMemoryOperation(reason: "用户取消")
    }
    private func cancelControllerMemoryOperation(reason: String) {
        guard controllerMemoryBusy else { return }
        controllerMemoryOperation?.cancel(reason: reason, at: clock())
        finishControllerMemoryOperation()
    }
    private func controllerMemoryContextIsValid(at now: TimeInterval) -> Bool {
        guard ready, controllerMemoryOperationSession == connectionSessionID,
              controllerMemoryOperationBase == baseHeight, presets == controllerMemoryOperationLocalPresets,
              let raw = rawHeight, let initialRaw = controllerMemoryOperationInitialRaw,
              motion == nil, speed.isFinite, abs(speed) < 0.1,
              now - lastFeedback >= 0, now - lastFeedback <= 1.5 else { return false }
        return abs(raw - initialRaw) < 15
    }
    private func controllerMemorySaveIsAuthorized(_ data: Data) -> Bool {
        guard !memoryVerificationOnly, controllerMemoryBusy, !controllerMemoryRequiresReconnect,
              controllerMemoryOperation?.writeSent == false,
              let target = controllerMemoryWriteTarget, let slot = controllerMemoryWriteSlot,
              let authorizedAt = controllerMemoryWriteAuthorizedAt,
              clock() - authorizedAt >= 0, clock() - authorizedAt <= 10,
              target.sessionID == connectionSessionID, target.baseHeight == baseHeight,
              controllerMemoryContextIsValid(at: clock()),
              ControllerMemoryProtocol.save(slot: slot, raw: target.raw) == data else { return false }
        return true
    }
    private func pumpControllerMemoryOperation(at now: TimeInterval) {
        guard controllerMemoryBusy else { return }
        guard controllerMemoryContextIsValid(at: now) else {
            controllerMemoryOperation?.cancel(reason: "连接、校准、位置或反馈已变化", at: now)
            finishControllerMemoryOperation()
            return
        }
        controllerMemoryOperation?.poll(at: now)
        if let command = controllerMemoryOperation?.nextCommand(at: now) {
            if write(command, to: DPI.config) {
                controllerMemoryDidSend = true
                controllerMemoryHasUsedProtocol = true
                controllerMemoryOperation?.didSend(at: now)
            } else {
                controllerMemoryOperation?.didFailToSend(at: now)
            }
        }
        updateControllerMemoryOperation()
    }
    private func updateControllerMemoryOperation() {
        guard controllerMemoryBusy, let operation = controllerMemoryOperation else { return }
        if operation.isFinished { finishControllerMemoryOperation() }
    }
    private func finishControllerMemoryOperation() {
        guard controllerMemoryBusy, let operation = controllerMemoryOperation else { return }
        let valid = controllerMemoryContextIsValid(at: clock())
        let failure = operation.failure ?? (valid ? nil : "完成时设备状态已变化")
        let slot = controllerMemoryWriteSlot
        controllerMemoryBusy = false
        for line in operation.trace { log("内部记忆 · \(line)") }
        if let failure {
            if controllerMemoryDidSend || operation.writeSent { controllerMemoryRequiresReconnect = true }
            let message = operation.writeSent
                ? "写入可能已生效，但尚未确认：\(failure)。请重新连接并刷新；不会自动重试或回滚。"
                : "操作未完成：\(failure)" + (controllerMemoryRequiresReconnect ? "。请重新连接后刷新。" : "。")
            if controllerMemoryDidSend || !valid { invalidateControllerMemoryCache(message: message) }
            else { controllerMemoryStatus = message }
        } else {
            if let slot { controllerMemoryCache[slot] = operation.replies[slot] }
            else { controllerMemoryCache = operation.replies }
            controllerMemoryCacheSession = connectionSessionID
            controllerMemoryCacheBase = baseHeight
            updateControllerMemoryRows()
            controllerMemoryStatus = slot.map { "\(controllerMemorySlotTitle($0))已保存" } ?? "已读取"
            log(controllerMemoryStatus)
        }
        detail = controllerMemoryStatus
        controllerMemoryOperation = nil
        controllerMemoryWriteTarget = nil
        controllerMemoryWriteSlot = nil
        controllerMemoryWriteAuthorizedAt = nil
    }
    private func updateControllerMemoryRows() {
        guard let base = baseHeight else { return }
        controllerMemoryRows = (0..<4).map { slot in
            guard let reply = controllerMemoryCache[slot], reply.isRecognizedStorageReply else {
                return ControllerMemoryRow(slot: slot, heightText: "未确认", detail: "请刷新后再写入", isLoaded: false, isEmpty: false)
            }
            let draft = reply.confirmedRaw.map { String(format: "%.2f", base + Double($0) / 100) } ?? ""
            if controllerMemoryDrafts[slot].isEmpty || controllerMemoryDrafts[slot] == controllerMemoryAutoDrafts[slot] {
                controllerMemoryDrafts[slot] = draft
            }
            controllerMemoryAutoDrafts[slot] = draft
            return ControllerMemoryRow(slot: slot, heightText: reply.confirmedRaw == nil ? "空档位" : draft + " cm",
                                       detail: "已从当前设备读取", isLoaded: true, isEmpty: reply.confirmedRaw == nil)
        }
    }
    private func invalidateControllerMemoryCache(message: String) {
        controllerMemoryCacheSession = nil
        controllerMemoryCacheBase = nil
        controllerMemoryCache = Array(repeating: nil, count: 4)
        controllerMemoryRows = ControllerMemoryRow.unread
        controllerMemoryStatus = message
    }
    func verifyControllerMemory() {
        guard canVerifyControllerMemory, let base = baseHeight, let raw = rawHeight else {
            memoryVerificationSummary = "请先连接桌子，等待静止且高度反馈更新。"
            return
        }
        memoryReadConnectionID = connectionSessionID
        memoryReadBase = base
        memoryReadInitialRaw = raw
        memoryReadOriginalPresets = presets
        memoryReadSession = ControllerMemoryReadSession(expectedBase: base, now: clock())
        memoryReadQuarantined = true
        memoryVerificationRunning = true
        memoryVerificationSummary = "正在串行读取四组记忆，两轮交叉核对…"
        log("开始内部记忆只读验证 · \(deskName) · 会话 \(connectionSessionID)")
        log(String(format: "验证前：基准 %.2f cm · 高度 %.2f cm · raw %d · 本地档位 %@", base, base + Double(raw) / 100, raw, String(describing: presets)))
    }
    private func pumpMemoryVerification(at now: TimeInterval) {
        guard memoryVerificationRunning else { return }
        guard memoryVerificationContextIsValid(at: now) else {
            finishMemoryVerification(failure: "连接、校准、位置或高度反馈发生变化，已中止只读验证")
            return
        }
        memoryReadSession?.poll(at: now)
        if let command = memoryReadSession?.nextCommand(at: now), write(command, to: DPI.config) {
            memoryReadSession?.didSend(at: now)
        }
        updateMemoryVerification()
    }
    private func memoryVerificationContextIsValid(at now: TimeInterval) -> Bool {
        guard ready, memoryReadConnectionID == connectionSessionID, baseHeight == memoryReadBase,
              presets == memoryReadOriginalPresets, let raw = rawHeight, let initialRaw = memoryReadInitialRaw else { return false }
        return abs(raw - initialRaw) < 15 && abs(speed) < 0.1 && now - lastFeedback <= 1.5
    }
    private func updateMemoryVerification() {
        guard memoryVerificationRunning, let session = memoryReadSession else { return }
        if session.isFinished {
            finishMemoryVerification(failure: session.failure)
        } else {
            let count = session.replies.flatMap { $0 }.compactMap { $0 }.count
            let summary = "正在只读核对：已收到 \(count)/8 个槽位回复"
            if memoryVerificationSummary != summary { memoryVerificationSummary = summary }
        }
    }
    private func finishMemoryVerification(failure: String?) {
        guard memoryVerificationRunning else { return }
        memoryVerificationRunning = false
        for line in memoryReadSession?.trace ?? [] { log("记忆验证 · \(line)") }
        let finalFailure = failure ?? (memoryVerificationContextIsValid(at: clock()) ? nil : "完成时连接、校准、位置或反馈已变化")
        if let finalFailure {
            memoryVerificationSummary = "只读验证未完成：\(finalFailure)"
        } else if let session = memoryReadSession, let base = memoryReadBase {
            var lines = ["两轮读取一致，前后高度基准一致。"]
            for slot in 0..<4 {
                guard let reply = session.replies[0][slot] else { continue }
                switch reply.state {
                case .empty: lines.append("记忆 \(slot + 1)：空槽")
                case .candidate(let raw, let metadata):
                    let flags = metadata.map { String(format: "%02X", $0) }.joined(separator: " ")
                    lines.append(String(format: "记忆 %d：候选高度 %.2f cm · raw %d · 标志 %@", slot + 1, base + Double(raw) / 100, raw, flags))
                case .unknown: lines.append("记忆 \(slot + 1)：未知回复，不能视为空槽")
                }
            }
            memoryVerificationSummary = lines.joined(separator: "\n")
        }
        log(memoryVerificationSummary)
        log("验证后：当前高度 \(heightText) cm · 基准 \(String(describing: baseHeight)) · 本地档位未改动：\(presets == memoryReadOriginalPresets)")
        detail = "只读验证已结束。运动保持禁用；退出并正常重开后才能恢复控制。"
    }
    func disconnect() {
        endScan()
        let p = peripheral
        stop("正在断开连接")
        // Allow the final stop packet to leave before closing the BLE link.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.peripheral == p else { return }
            if let p { self.central?.cancelPeripheralConnection(p) }
            self.clearSession(); self.status = "尚未连接"; self.detail = "点击搜索桌子重新连接。"
        }
    }
    private func fail(_ message: String) {
        log(message); stop(message)
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        clearSession(); status = "暂时无法连接"; detail = message
    }
    private func clearSession() {
        if controllerMemoryBusy { cancelControllerMemoryOperation(reason: "蓝牙会话已结束") }
        controllerMemoryOperation = nil
        controllerMemoryWriteTarget = nil; controllerMemoryWriteSlot = nil; controllerMemoryWriteAuthorizedAt = nil
        controllerMemoryRequiresReconnect = false
        initialConfigQueue = []; initialConfigPending = nil; initialConfigDeadline = nil; initialConfigQueuedAt = nil
        lastInitialConfigReply = -Double.infinity
        invalidateControllerMemoryCache(message: "未读取")
        controllerMemoryDrafts = Array(repeating: "", count: 4)
        controllerMemoryAutoDrafts = Array(repeating: "", count: 4)
        controllerMemoryNamingDeviceID = nil
        controllerMemoryCustomNames = Array(repeating: "", count: 4)
        if memoryVerificationRunning { finishMemoryVerification(failure: "蓝牙会话已结束") }
        if !memoryVerificationOnly { memoryReadQuarantined = false }
        connectionSessionID = UUID()
        if let id = motionID {
            lastMotionResult = MotionResult(id: id, reachedTarget: false, reason: "蓝牙连接已断开")
        }
        tick?.invalidate(); tick = nil; connectTimeout?.invalidate()
        scanTimeout?.invalidate(); central?.stopScan(); scanning = false
        connecting = false; ready = false; motion = nil; motionID = nil; activeTarget = nil
        rawHeight = nil; baseHeight = nil; speed = 0; lastFeedback = -.infinity
        chars = [:]; notified = []; peripheral = nil; stopPending = false; presets = [nil, nil]
    }
    func exportLog() {
        if motion != nil { stop("导出日志前已停止升降") }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "DeskLift-\(Self.stamp()).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try logs.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { detail = "保存日志失败：\(error.localizedDescription)" }
    }
    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss"; return f.string(from: Date())
    }
}
