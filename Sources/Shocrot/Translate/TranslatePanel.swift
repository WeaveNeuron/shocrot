import AppKit
import SwiftUI

/// The single floating translation window used by input, selection and screenshot translation.
/// It never activates the app, and closes on a click outside unless pinned.
/// Its header is the drag handle; the panel stays inside the visible area of its display as its content grows.
final class TranslatePanel: NSPanel {
    private static var shared: TranslatePanel?

    /// Height planned for when placing the panel: it opens small ("recognizing") and grows as results arrive,
    /// so placing it by its current height alone would leave the results running off the screen.
    static let plannedHeight: CGFloat = 420

    let model = TranslateModel()
    private var clickMonitors: [Any] = []
    /// The display chosen when the panel was placed; used while the panel is not on any display yet.
    private weak var placementScreen: NSScreen?

    /// `anchor`: what the panel belongs to, in AppKit global coordinates: the captured area, or a point
    /// (zero-size rect) for a text selection. Without one the panel goes centred on the display under the pointer.
    @MainActor
    static func show(text: String? = nil, near anchor: CGRect? = nil) {
        let panel = shared ?? TranslatePanel()
        shared = panel
        if !panel.isVisible || !panel.model.pinned { panel.place(near: anchor) }
        panel.orderFrontRegardless()
        panel.makeKey()
        panel.watchOutsideClicks()
        if let text { panel.model.query(text) } else { panel.model.translate() }
        NotificationCenter.default.post(name: .focusTranslateInput, object: nil)
    }

    /// Builds the panel ahead of time so the first translation opens as fast as later ones.
    @MainActor
    static func prepare() {
        if shared == nil { shared = TranslatePanel() }
    }

    /// Opens the panel immediately in a "recognizing" state; follow up with `show(text:near:)`.
    @MainActor
    static func showRecognizing(near anchor: CGRect?) {
        let panel = shared ?? TranslatePanel()
        shared = panel
        panel.model.clear()
        panel.model.isRecognizing = true
        if !panel.isVisible || !panel.model.pinned { panel.place(near: anchor) }
        panel.orderFrontRegardless()
        panel.watchOutsideClicks()
    }

    /// Ends a recognizing state that produced no text.
    @MainActor
    static func cancelRecognizing() {
        guard let panel = shared, panel.model.isRecognizing else { return }
        panel.model.isRecognizing = false
        panel.dismissIfUnpinned()
    }

    /// Gets an unpinned panel out of the way, e.g. before a new screenshot.
    @MainActor
    static func dismissUnpinned() {
        shared?.dismissIfUnpinned()
    }

    private init() {
        super.init(contentRect: CGRect(x: 0, y: 0, width: 420, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // SwiftUI content never lets a background drag move the window; the header carries a WindowDragGesture.
        isMovableByWindowBackground = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let host = NSHostingController(rootView: TranslateView(model: model) { [weak self] in self?.close() })
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
        // The hosting controller resizes the window with its content, keeping the top left fixed; pull it back
        // inside the display whenever that makes it run past an edge.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
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

    /// Next to the anchor (below, above, beside) on the display that shows it, else centred in the upper part of
    /// the display under the pointer; always inside that display's visible frame.
    private func place(near anchor: CGRect?) {
        let screen = anchor.flatMap(WindowPlacement.screen(for:)) ?? WindowPlacement.mouseScreen
        guard let screen else { return }
        placementScreen = screen
        let vf = screen.visibleFrame
        let size = CGSize(width: frame.width, height: min(max(frame.height, Self.plannedHeight), vf.height))
        let topLeft = anchor.map { WindowPlacement.topLeft(for: size, beside: $0, in: vf) }
            ?? WindowPlacement.centeredTopLeft(for: size, in: vf)
        setFrameTopLeftPoint(topLeft)
        keepOnScreen()
    }

    /// Moves the panel back inside the visible frame of the display it is on (the one it was placed on while it
    /// is on none); a panel taller than the display keeps its header in view.
    private func keepOnScreen() {
        guard let screen = WindowPlacement.screen(for: frame) ?? placementScreen ?? WindowPlacement.mouseScreen
        else { return }
        let fitted = WindowPlacement.fit(frame, in: screen.visibleFrame)
        if fitted.origin != frame.origin { setFrameOrigin(fitted.origin) }
    }
}

extension Notification.Name {
    static let focusTranslateInput = Notification.Name("ShocrotFocusTranslateInput")
}
