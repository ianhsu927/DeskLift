import AppKit
import SwiftUI

struct HoldControl: NSViewRepresentable {
    var title: String
    var symbol: String
    var enabled: Bool
    var press: () -> Void
    var release: () -> Void

    func makeNSView(context: Context) -> HoldButton {
        let b = HoldButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.font = .systemFont(ofSize: 13, weight: .medium)
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        b.imagePosition = .imageLeading
        b.setContentHuggingPriority(.defaultLow, for: .horizontal)
        b.setAccessibilityLabel(title + "，按住移动，松开停止")
        return b
    }

    func updateNSView(_ b: HoldButton, context: Context) {
        b.title = title
        b.isEnabled = enabled
        b.allowed = enabled
        b.press = press
        b.release = release
    }

    static func dismantleNSView(_ b: HoldButton, coordinator: ()) { b.finish() }
}

final class HoldButton: NSButton {
    var allowed = false
    var press: (() -> Void)?
    var release: (() -> Void)?
    private var tracking = false
    private var pulseTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    override func mouseDown(with event: NSEvent) {
        guard allowed, isEnabled, !tracking, pulseTimer == nil else { return }
        tracking = true
        isHighlighted = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .leftMouseDragged]) { [weak self] e in
            if e.type == .leftMouseUp { self?.finish() }
            else if let self {
                if e.window !== self.window || !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) { self.finish() }
            }
            return e
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in self?.finish() }
        press?()
    }

    override func mouseUp(with event: NSEvent) { finish() }

    override func mouseDragged(with event: NSEvent) {
        guard tracking else { return }
        if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
            finish()
        }
    }

    override func keyDown(with event: NSEvent) {
        guard allowed, isEnabled else { return }
        // Keyboard users get a short pulse, never a latched motion.
        if event.keyCode == 49 || event.keyCode == 36 {
            _ = beginPulse()
        } else { super.keyDown(with: event) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard allowed, isEnabled else { return false }
        return beginPulse()
    }

    private func beginPulse() -> Bool {
        guard !tracking, pulseTimer == nil else { return false }
        let timer = Timer(timeInterval: 0.2, repeats: false) { [weak self] _ in self?.finish() }
        pulseTimer = timer
        // A menu tracks in NSEventTrackingRunLoopMode. Common modes keep the
        // same 0.2-second release deadline while that menu remains open.
        RunLoop.main.add(timer, forMode: .common)
        press?()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finish() }
    }

    func finish() {
        guard tracking || pulseTimer != nil else { return }
        tracking = false
        isHighlighted = false
        pulseTimer?.invalidate()
        pulseTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        release?()
    }
}
