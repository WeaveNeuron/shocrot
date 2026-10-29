import AppKit
import SwiftUI

/// The single floating translation window used by input, selection and screenshot translation.
/// It never activates the app, and closes on a click outside unless pinned.
final class TranslatePanel: NSPanel {
    private static var shared: TranslatePanel?

    let model = TranslateModel()
    private var clickMonitors: [Any] = []

    @MainActor
    static func show(text: String? = nil, near point: CGPoint? = nil) {
        let panel = shared ?? TranslatePanel()
        shared = panel
        if !panel.isVisible || !panel.model.pinned { panel.place(near: point) }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.watchOutsideClicks()
        if let text { panel.model.query(text) } else { panel.model.translate() }
        NotificationCenter.default.post(name: .focusTranslateInput, object: nil)
    }

    private init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let host = NSHostingController(rootView: TranslateView(model: model))
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
    }

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func close() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        Speaker.shared.stop()
        super.close()
    }

    /// Clicking anywhere else (other apps or our other windows) dismisses an unpinned panel.
    private func watchOutsideClicks() {
        guard clickMonitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.dismissIfUnpinned()
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            if event.window !== self { self?.dismissIfUnpinned() }
            return event
        }) { clickMonitors.append(local) }
    }

    private func dismissIfUnpinned() {
        guard !model.pinned, isVisible, attachedSheet == nil else { return }
        close()
    }

    /// Below the cursor for selections, otherwise in the upper third of the active screen.
    private func place(near point: CGPoint?) {
        let mouse = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let size = CGSize(width: 420, height: max(frame.height, 200))
        var origin: CGPoint
        if let point {
            origin = CGPoint(x: point.x - 40, y: point.y - 16 - size.height)
        } else {
            origin = CGPoint(x: vf.midX - size.width / 2, y: vf.maxY - vf.height * 0.18 - size.height)
        }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        setFrameTopLeftPoint(CGPoint(x: origin.x, y: origin.y + size.height))
    }
}

extension Notification.Name {
    static let focusTranslateInput = Notification.Name("ShocrotFocusTranslateInput")
}
