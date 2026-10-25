import AppKit
import SwiftUI
import Combine

final class InterfaceState: ObservableObject {
    @Published var showingDevices = false
}

struct MainView: View {
    @ObservedObject var model: DeskModel
    @ObservedObject var interfaceState: InterfaceState
    var showDiagnostics: () -> Void
    var showControllerMemory: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            heightControls
            Form {
                Section {
                    LabeledContent("目标高度") {
                        HStack(spacing: 8) {
                            TextField("厘米", text: $model.targetText)
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                                .accessibilityLabel("目标高度，厘米")
                                .disabled(!model.canMove)
                            Text("cm").foregroundStyle(.secondary)
                            Button("前往") { model.goToTarget() }
                                .disabled(!model.canMove)
                                .help("移动到输入的目标高度")
                        }
                    }
                } footer: {
                    Text(model.rangeText)
                }
                Section("常用高度") {
                    presetRow(0, name: "坐姿", symbol: "chair.fill")
                    presetRow(1, name: "站姿", symbol: "figure.stand")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 250)

            Spacer(minLength: 0)

            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "info.circle")
                Text(model.detail).frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24)
            .padding(.bottom, 18)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .frame(minWidth: 460, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if model.isActive { model.stop("打开设备面板，已停止升降") }
                    interfaceState.showingDevices.toggle()
                } label: {
                    Label("设备", systemImage: "antenna.radiowaves.left.and.right")
                }
                .help("搜索、连接或断开升降桌")
                .popover(isPresented: $interfaceState.showingDevices, arrowEdge: .top) {
                    ConnectionView(model: model)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: showControllerMemory) {
                    Label("控制器记忆", systemImage: "internaldrive")
                }
                .help("读取或写入设备的四组内部记忆")
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: showDiagnostics) {
                    Label("连接诊断", systemImage: "waveform.path.ecg")
                }
                .help("打开连接诊断")
            }
        }
        .onChange(of: model.ready) { _, ready in
            if ready { interfaceState.showingDevices = false }
        }
    }

    private var heightControls: some View {
        VStack(spacing: 16) {
            HStack {
                Label(model.deskName, systemImage: "table.furniture")
                Spacer()
                HStack(spacing: 5) {
                    Circle().fill(model.ready ? Color.green : Color.secondary).frame(width: 6, height: 6)
                    Text(model.status)
                }
            }.font(.subheadline).foregroundStyle(.secondary)

            VStack(spacing: 3) {
                Text("当前高度").font(.subheadline).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(model.heightText)
                        .font(.system(size: 64, weight: .regular, design: .rounded))
                        .monospacedDigit()
                    Text("cm").font(.title3).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(model.height == nil ? "尚未读取高度" : "当前高度 \(model.heightText) 厘米")
                Text(model.height == nil ? "连接升降桌后显示" : (model.isActive ? "正在升降" : "按住升降，松开即停"))
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                HoldControl(title: "按住下降", symbol: "arrow.down", enabled: model.canMove || model.isActive,
                            press: { model.hold(up: false) }, release: { model.stop() })
                    .disabled(!model.canMove && !model.isActive)
                    .frame(maxWidth: .infinity).frame(height: 36)
                Button { model.stop() } label: {
                    Label("停止", systemImage: "stop.fill")
                        .frame(minWidth: 54)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .disabled(!model.ready)
                .help("停止升降（Esc）")
                HoldControl(title: "按住上升", symbol: "arrow.up", enabled: model.canMove || model.isActive,
                            press: { model.hold(up: true) }, release: { model.stop() })
                    .disabled(!model.canMove && !model.isActive)
                    .frame(maxWidth: .infinity).frame(height: 36)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 6)
    }

    private func presetRow(_ slot: Int, name: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Label(name, systemImage: symbol)
            Spacer(minLength: 8)
            Text(model.presetLabel(slot)).foregroundStyle(.secondary).monospacedDigit()
            Button { model.savePreset(slot) } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .accessibilityLabel("保存当前高度为\(name)")
            .help("将当前高度保存为\(name)")
            .disabled(!model.canMove)
            Button("前往") { model.recallPreset(slot) }
                .accessibilityLabel("前往\(name)高度")
                .disabled(!model.canMove || model.presets[slot] == nil)
        }
        .accessibilityElement(children: .contain)
    }
}

struct ConnectionView: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("升降桌设备").font(.headline)
                Spacer()
                if model.scanning || model.connecting { ProgressView().controlSize(.small) }
            }
            if model.ready || model.connecting {
                Label(model.deskName, systemImage: "table.furniture")
                Text(model.ready ? "已连接 · 当前高度 \(model.heightText) cm" : "正在连接并读取高度…")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("断开连接") { model.disconnect() }
            } else {
                Text("按住 DPI1C 底部连接键约 2 秒，屏幕显示 DESK 编号后搜索。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.devices.isEmpty {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(model.devices) { desk in
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(desk.name)
                                        Text("\(desk.rssi) dBm · \(desk.connectable ? "可连接" : "等待配对")")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("连接") { model.connect(desk.id) }.disabled(!desk.connectable)
                                }
                            }
                        }
                    }.frame(height: min(CGFloat(model.devices.count) * 48, 180))
                }
                Button(model.scanning ? "停止搜索" : "搜索桌子") {
                    model.scanning ? model.endScan() : model.scan()
                }
                .buttonStyle(.borderedProminent)
            }
            Divider()
            Toggle("启动时自动连接", isOn: Binding(
                get: { model.autoConnectEnabled },
                set: { model.setAutoConnectEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.memoryVerificationOnly)
        }.padding(20).frame(width: 320)
    }
}

struct DiagnosticsView: View {
    @ObservedObject var model: DeskModel

    var body: some View {
        VStack(spacing: 0) {
            LabeledContent("连接状态", value: model.status)
                .font(.subheadline).padding(16)
            Divider()
            if model.memoryVerificationOnly {
                VStack(alignment: .leading, spacing: 8) {
                    Text("只读验证 · 升降与保存已禁用").font(.headline)
                    Text(model.memoryVerificationSummary).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
                Divider()
            }
            ScrollView {
                Text(model.logs.joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .frame(minWidth: 480, minHeight: 300)
        .toolbar {
            if model.memoryVerificationOnly {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.verifyControllerMemory() } label: {
                        Label("读取控制器记忆", systemImage: "internaldrive")
                    }.disabled(!model.canVerifyControllerMemory)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button { model.exportLog() } label: {
                    Label("导出日志…", systemImage: "square.and.arrow.up")
                }
            }
        }
    }
}

private final class ConnectionDotView: NSView {
    var connected = false {
        didSet { if oldValue != connected { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        (connected ? NSColor.systemGreen : NSColor.systemRed).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class StatusMenuSummaryView: NSView {
    private let dot = ConnectionDotView(frame: .zero)
    private let heightLabel = NSTextField(labelWithString: "高度与持续时间 —")

    init(width: CGFloat = 288) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 28))
        autoresizingMask = [.width]
        heightLabel.font = .menuFont(ofSize: 13)
        heightLabel.textColor = .labelColor
        heightLabel.lineBreakMode = .byTruncatingTail
        for view in [dot, heightLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            view.setAccessibilityElement(false)
        }
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            heightLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            heightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            heightLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(connected: Bool, height: String, connectionDescription: String) {
        dot.connected = connected
        if heightLabel.stringValue != height { heightLabel.stringValue = height }
        toolTip = connectionDescription
        setAccessibilityLabel(connectionDescription + "，" + height)
    }
}

final class StatusMenuControls: NSView {
    private let down = HoldButton(title: "下降", target: nil, action: nil)
    private let up = HoldButton(title: "上升", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private let sitting = NSButton(title: "坐姿", target: nil, action: nil)
    private let standing = NSButton(title: "站姿", target: nil, action: nil)
    private let hold: (Bool) -> Void
    private let stop: () -> Void
    private let recall: (Int) -> Void

    init(hold: @escaping (Bool) -> Void, stop: @escaping () -> Void, recall: @escaping (Int) -> Void) {
        self.hold = hold; self.stop = stop; self.recall = recall
        super.init(frame: NSRect(x: 0, y: 0, width: 288, height: 80))
        autoresizingMask = [.width]
        for button in [down, stopButton, up, sitting, standing] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = .menuFont(ofSize: 13)
            button.imagePosition = .imageLeading
        }
        down.image = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)
        up.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        stopButton.image = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: nil)
        stopButton.contentTintColor = .systemRed
        sitting.image = NSImage(systemSymbolName: "chair.fill", accessibilityDescription: nil)
        standing.image = NSImage(systemSymbolName: "figure.stand", accessibilityDescription: nil)
        down.setAccessibilityLabel("按住下降，松开停止")
        up.setAccessibilityLabel("按住上升，松开停止")
        down.press = { [weak self] in self?.hold(false) }
        up.press = { [weak self] in self?.hold(true) }
        down.release = { [weak self] in self?.stop() }
        up.release = { [weak self] in self?.stop() }
        stopButton.target = self; stopButton.action = #selector(stopPressed)
        sitting.target = self; sitting.action = #selector(sitPressed)
        standing.target = self; standing.action = #selector(standPressed)
        let motionRow = NSStackView(views: [down, stopButton, up])
        let presetRow = NSStackView(views: [sitting, standing])
        for row in [motionRow, presetRow] {
            row.orientation = .horizontal
            row.distribution = .fillEqually
            row.alignment = .centerY
            row.spacing = 6
        }
        let rows = NSStackView(views: [motionRow, presetRow])
        rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 8
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            motionRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            presetRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            motionRow.heightAnchor.constraint(equalToConstant: 30),
            presetRow.heightAnchor.constraint(equalToConstant: 30)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(_ model: DeskModel) {
        let enabled = model.canMove || model.isActive
        down.allowed = enabled; down.isEnabled = enabled
        up.allowed = enabled; up.isEnabled = enabled
        stopButton.isEnabled = model.ready
        sitting.title = model.presets[0] == nil ? "坐姿" : "坐姿 · " + model.presetLabel(0)
        standing.title = model.presets[1] == nil ? "站姿" : "站姿 · " + model.presetLabel(1)
        sitting.isEnabled = model.canMove && model.presets[0] != nil
        standing.isEnabled = model.canMove && model.presets[1] != nil
        sitting.setAccessibilityLabel("前往坐姿高度，" + model.presetLabel(0))
        standing.setAccessibilityLabel("前往站姿高度，" + model.presetLabel(1))
    }
    func finishTracking() { down.finish(); up.finish() }
    @objc private func stopPressed() { stop() }
    @objc private func sitPressed() { recall(0) }
    @objc private func standPressed() { recall(1) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = DeskModel(preview: CommandLine.arguments.contains("--preview"),
                          memoryVerificationOnly: CommandLine.arguments.contains("--verify-controller-memory"))
    private let interfaceState = InterfaceState()
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var eventMonitor: Any?
    var diagnosticsWindow: NSWindow?
    private var siriSettingsWindow: NSWindow?
    private var controllerMemoryWindow: NSWindow?
    private let statusMenu = NSMenu()
    private let statusHeightItem = NSMenuItem(title: "当前高度 —", action: nil, keyEquivalent: "")
    private let statusSummary = StatusMenuSummaryView()
    private var statusStopItem: NSMenuItem!
    private var statusControls: StatusMenuControls!
    private var statusMenuIsOpen = false
    private var statusMouseMonitor: Any?
    private var statusGlobalMouseMonitor: Any?
    private var statusSubscriptions = Set<AnyCancellable>()
    private var heightDuration = HeightDurationTracker()
    private var heightFeedbackAt: TimeInterval?
    private var statusClock: Timer?
    private var statusRefreshPending = false
    private let clock = { ProcessInfo.processInfo.systemUptime }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "DeskLift"; window.delegate = self; window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        window.autorecalculatesKeyViewLoop = true
        let host = NSHostingView(rootView: MainView(model: model, interfaceState: interfaceState,
            showDiagnostics: { [weak self] in self?.showDiagnostics() },
            showControllerMemory: { [weak self] in self?.showControllerMemory() }))
        host.sceneBridgingOptions = [.toolbars]
        window.contentView = host
        window.center(); window.makeKeyAndOrderFront(nil)
        buildMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "table.furniture", accessibilityDescription: "DeskLift 升降桌控制")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem.autosaveName = "DeskLiftControl"
        configureStatusMenu()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                if self?.statusMenuIsOpen == true {
                    self?.model.stop()
                    self?.closeStatusMenu()
                    return nil
                }
                let wasActive = self?.model.isActive == true
                self?.model.stop()
                return wasActive ? nil : event
            }
            return event
        }
        NSApp.activate(ignoringOtherApps: true)
        model.startAutomaticConnection()
    }

    private func configureStatusMenu() {
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false
        statusMenu.minimumWidth = 288
        statusHeightItem.isEnabled = false
        statusHeightItem.view = statusSummary
        statusMenu.addItem(statusHeightItem)
        statusMenu.addItem(.separator())
        statusControls = StatusMenuControls(
            hold: { [weak self] up in self?.performStatusAction { self?.model.hold(up: up) } },
            stop: { [weak self] in
                guard let self else { return }
                self.model.stop()
                self.statusControls.update(self.model)
            },
            recall: { [weak self] slot in self?.performStatusAction { self?.model.recallPreset(slot) } }
        )
        let controlsItem = NSMenuItem()
        controlsItem.view = statusControls
        statusMenu.addItem(controlsItem)
        statusStopItem = statusMenu.addItem(withTitle: "停止升降", action: #selector(stopDesk), keyEquivalent: ".")
        statusStopItem.target = self
        statusStopItem.isHidden = true
        statusStopItem.allowsKeyEquivalentWhenHidden = true
        statusItem.menu = statusMenu
        refreshStatusMenu()

        model.objectWillChange.sink { [weak self] _ in
            // @Published emits before assignment. Refresh on the next main-queue turn,
            // which also keeps item updates outside menuWillOpen/menuDidClose.
            self?.queueStatusRefresh()
        }.store(in: &statusSubscriptions)
        model.$rawHeight.sink { [weak self] raw in
            guard let self else { return }
            let now = self.clock()
            if let previous = self.heightFeedbackAt, now < previous || now - previous > 3 {
                self.heightDuration.observe(height: nil, isMoving: false, now: now)
            }
            self.heightFeedbackAt = raw == nil ? nil : now
            if raw == nil { self.heightDuration.observe(height: nil, isMoving: false, now: now) }
        }.store(in: &statusSubscriptions)
        model.$activeTarget.sink { [weak self] target in
            if target != nil { self?.resetMovingDuration() }
        }.store(in: &statusSubscriptions)
        model.$speed.sink { [weak self] speed in
            guard let self else { return }
            let now = self.clock()
            let fresh = self.heightFeedbackAt.map { now >= $0 && now - $0 <= 3 } ?? false
            // DeskModel publishes rawHeight before speed for each complete status
            // packet. Use that new pair, never the timer's cached height, to start.
            self.heightDuration.observe(height: self.model.ready && fresh ? self.model.height : nil,
                                        isMoving: self.model.isActive || abs(speed) >= 0.1, now: now)
        }.store(in: &statusSubscriptions)
        model.$ready.sink { [weak self] ready in
            guard let self, !ready else { return }
            self.heightFeedbackAt = nil
            self.heightDuration.observe(height: nil, isMoving: false, now: self.clock())
        }.store(in: &statusSubscriptions)
        model.$baseHeight.sink { [weak self] base in
            guard let self, base != self.model.baseHeight else { return }
            self.heightDuration.observe(height: nil, isMoving: false, now: self.clock())
        }.store(in: &statusSubscriptions)
        statusClock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatusMenu() }
        RunLoop.main.add(statusClock!, forMode: .common)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.closeStatusMenu()
            }
            .store(in: &statusSubscriptions)
    }

    private var heightIsMoving: Bool { model.isActive || abs(model.speed) >= 0.1 }

    private func resetMovingDuration() {
        // Observe motion immediately, including pulses shorter than the display timer.
        heightDuration.observe(height: model.height, isMoving: true, now: clock())
    }

    private func queueStatusRefresh() {
        guard !statusRefreshPending else { return }
        statusRefreshPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusRefreshPending = false
            self.refreshStatusMenu()
        }
    }

    private func refreshStatusMenu() {
        let now = clock()
        let height = model.ready ? model.height.map { String(format: "%.1f cm", $0) } : nil
        let fresh = heightFeedbackAt.map { now >= $0 && now - $0 <= 3 } ?? false
        if !model.ready || !fresh {
            heightDuration.observe(height: nil, isMoving: false, now: now)
        }
        let connection = model.ready ? "已连接" : model.status
        statusItem.button?.title = height.map { " " + $0 } ?? ""
        statusItem.button?.appearsDisabled = !model.ready
        statusItem.button?.toolTip = "DeskLift · \(connection)" + (model.ready ? " · \(model.deskName)" : "") + (height.map { " · " + $0 } ?? "")
        statusItem.button?.setAccessibilityLabel("DeskLift，\(connection)" + (height.map { "，当前高度 " + $0 } ?? "") + "，菜单栏升降控制")
        let heightTitle: String
        if let height {
            if !fresh { heightTitle = "\(height) · 等待高度更新" }
            else if heightIsMoving { heightTitle = "\(height) · 升降中" }
            else if let elapsed = heightDuration.elapsed(at: now) {
                heightTitle = "\(height) · 已保持 \(HeightDurationTracker.format(elapsed))"
            } else { heightTitle = "\(height) · 等待静止读数" }
        } else { heightTitle = "高度与持续时间 —" }
        if statusHeightItem.title != heightTitle { statusHeightItem.title = heightTitle }
        statusSummary.update(connected: model.ready, height: heightTitle, connectionDescription: connection)
        statusStopItem.isEnabled = model.ready
        statusControls.update(model)
    }

    private func performStatusAction(_ action: () -> Void) {
        // Native menu tracking is the interaction context; it does not activate the app.
        guard statusMenuIsOpen, statusControls.window?.isVisible == true else { return }
        action()
        statusControls.update(model)
    }

    private func closeStatusMenu() {
        guard statusMenuIsOpen else { return }
        statusMenuIsOpen = false
        if model.isActive { model.stop("菜单栏菜单已关闭，升降已停止") }
        statusControls.finishTracking()
        statusMenu.cancelTracking()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu { refreshStatusMenu() }
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { closeStatusMenu(); return }
        if model.isActive { model.stop("切换到菜单栏控制，已停止本次升降") }
        statusMenuIsOpen = true
        model.log("菜单栏控制已展开")
        statusMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            if let self, event.window !== self.statusControls.window,
               event.window !== self.statusItem.button?.window { self.closeStatusMenu() }
            return event
        }
        statusGlobalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.closeStatusMenu()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        statusMenuIsOpen = false
        if model.isActive { model.stop("菜单栏菜单已关闭，升降已停止") }
        statusControls.finishTracking()
        model.log("菜单栏控制已收起")
        if let statusMouseMonitor { NSEvent.removeMonitor(statusMouseMonitor); self.statusMouseMonitor = nil }
        if let statusGlobalMouseMonitor { NSEvent.removeMonitor(statusGlobalMouseMonitor); self.statusGlobalMouseMonitor = nil }
    }

    @objc func showMenuBarPanel() {
        guard !statusMenuIsOpen, let button = statusItem.button else { return }
        statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button)
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let app = NSMenu(); appItem.submenu = app; app.delegate = self
        app.addItem(withTitle: "关于 DeskLift", action: #selector(about), keyEquivalent: "").target = self
        app.addItem(withTitle: "Siri 与快捷指令…", action: #selector(showSiriSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "退出 DeskLift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "编辑"); editItem.submenu = edit; edit.delegate = self
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windows = NSMenu(title: "窗口"); windowItem.submenu = windows; windows.delegate = self
        windows.addItem(withTitle: "控制面板", action: #selector(showWindow), keyEquivalent: "1").target = self
        windows.addItem(withTitle: "连接诊断", action: #selector(showDiagnostics), keyEquivalent: "2").target = self
        windows.addItem(withTitle: "菜单栏控制", action: #selector(showMenuBarPanel), keyEquivalent: "3").target = self
        windows.addItem(withTitle: "控制器记忆", action: #selector(showControllerMemory), keyEquivalent: "4").target = self
        windows.addItem(.separator())
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.windowsMenu = windows
        NSApp.mainMenu = main
    }
    @objc func showWindow() { closeStatusMenu(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func stopDesk() { model.stop(); statusControls.update(model) }
    @objc func showControllerMemory() {
        closeStatusMenu()
        if model.isActive { model.stop("打开控制器记忆，已停止升降") }
        if controllerMemoryWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 440), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            panel.title = "控制器记忆"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.toolbarStyle = .unifiedCompact
            let host = NSHostingView(rootView: ControllerMemoryView(model: model))
            host.sceneBridgingOptions = [.toolbars]
            panel.contentView = host
            panel.center()
            controllerMemoryWindow = panel
        }
        controllerMemoryWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if model.controllerMemoryRows.allSatisfy({ !$0.isLoaded }), model.canRefreshControllerMemory {
            model.refreshControllerMemory()
        }
    }
    @objc func showSiriSettings() {
        closeStatusMenu()
        if model.isActive { model.stop("打开 Siri 设置，已停止升降") }
        if siriSettingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 610), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = "Siri 与快捷指令"
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: SiriSettingsView())
            panel.center()
            siriSettingsWindow = panel
        }
        siriSettingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showDiagnostics() {
        closeStatusMenu()
        if model.isActive { model.stop("打开连接诊断，已停止升降") }
        if diagnosticsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            panel.title = "连接诊断"
            panel.isReleasedWhenClosed = false
            panel.toolbarStyle = .unifiedCompact
            panel.autorecalculatesKeyViewLoop = true
            let host = NSHostingView(rootView: DiagnosticsView(model: model))
            host.sceneBridgingOptions = [.toolbars]
            panel.contentView = host
            panel.center()
            diagnosticsWindow = panel
        }
        diagnosticsWindow?.makeKeyAndOrderFront(nil)
    }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "DeskLift", .applicationVersion: "1.0", .credits: NSAttributedString(string: "原生 macOS · LINAK DPI1C 蓝牙控制\n独立工具，与 LINAK 无隶属关系。\n协议参考 KKQQ 开源项目（MIT）。")])
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { model.stop("控制面板已关闭，升降已停止"); sender.orderOut(nil); return false }
    func windowDidResignKey(_ notification: Notification) { if model.isActive { model.stop("控制面板失去焦点，已停止") } }
    func windowDidMiniaturize(_ notification: Notification) { model.stop("窗口已最小化，升降已停止") }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        closeStatusMenu()
        statusClock?.invalidate(); statusClock = nil
        model.disconnect()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
