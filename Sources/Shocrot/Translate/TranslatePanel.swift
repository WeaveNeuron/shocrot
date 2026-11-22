import AppKit
import SwiftUI

/// The single floating translation window used by input, selection and screenshot translation.
/// It never activates the app, and closes on a click outside unless pinned.
/// Its header is the drag handle. The panel stays inside the visible area of its display: its content is capped
/// to that height (long text scrolls), and it is pulled back on screen when its content grows or a drag ends.
final class TranslatePanel: NSPanel {
    private static var shared: TranslatePanel?

    /// Height planned for when placing the panel: it opens small ("recognizing") and grows as results arrive,
    /// so placing it by its current height alone would leave the results running off the screen.
    static let plannedHeight: CGFloat = 420

    let model = TranslateModel()
    private var clickMonitors: [Any] = []
    /// The display chosen when the panel was placed; used while the panel is not on any display yet.
    private weak var placementScreen: NSScreen?
    private var keeper: OnScreenKeeper?

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
        // The hosting controller resizes the window with its content, keeping the top left fixed, and the header
        // drag can leave it past an edge: pull it back inside the display after either (after the drag ends).
        keeper = OnScreenKeeper(window: self) { [weak self] in
            (self?.connectedPlacementScreen ?? WindowPlacement.mouseScreen)?.visibleFrame
        }
        // Dragged to another display, or the display itself changed (resolution, Dock, unplugged): cap the
        // content to the height the panel's display has now.
        for (name, object) in [(NSWindow.didChangeScreenNotification, self as AnyObject?),
                               (NSApplication.didChangeScreenParametersNotification, nil)] {
            NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateHeightLimit() }
            }
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
        model.maxPanelHeight = WindowPlacement.maxHeight(in: vf)
        let size = CGSize(width: frame.width, height: min(max(frame.height, Self.plannedHeight), model.maxPanelHeight))
        let topLeft = anchor.map { WindowPlacement.topLeft(for: size, beside: $0, in: vf) }
            ?? WindowPlacement.centeredTopLeft(for: size, in: vf)
        setFrameTopLeftPoint(topLeft)
        // Its current height can differ from the planned one (taller from a previous translation).
        keeper?.pullBackNow()
    }

    /// The display the panel was placed on, while it is still connected: an unplugged one can linger with its
    /// old frame.
    private var connectedPlacementScreen: NSScreen? {
        placementScreen.flatMap { placed in NSScreen.screens.contains { $0 === placed } ? placed : nil }
    }

    private func updateHeightLimit() {
        guard let screen = self.screen ?? connectedPlacementScreen else { return }
        let limit = WindowPlacement.maxHeight(in: screen.visibleFrame)
        if model.maxPanelHeight != limit { model.maxPanelHeight = limit }
    }
}

/// The translation panel's vertical layout, kept here so the height cap can be checked without a window:
/// header, input and language bar on top (the "chrome"), then the results list, which scrolls.
enum TranslatePanelLayout {
    static let topPadding: CGFloat = 10
    static let bottomPadding: CGFloat = 12
    static let spacing: CGFloat = 10
    static let inputMinHeight: CGFloat = 44
    /// Longer input (a full-screen OCR) scrolls inside the editor.
    static let inputMaxHeight: CGFloat = 140
    /// The results list never grows past this, even on a tall display.
    static let resultsMaxHeight: CGFloat = 460
    /// Room the results keep however little the display has left.
    static let resultsMinHeight: CGFloat = 80
    /// The system's own behaviour: a scroller appears when the capped results run longer than the list (and per
    /// the "Show scroll bars" setting), so it is clear there is more to scroll to.
    static let resultsScrollIndicators: ScrollIndicatorVisibility = .automatic

    /// Height of the input editor for text whose natural height is `natural`.
    static func inputHeight(natural: CGFloat) -> CGFloat {
        min(max(natural, inputMinHeight), inputMaxHeight)
    }

    /// Height of the results list showing `content` points of results below `chrome`, so the whole panel stays
    /// within `maxPanelHeight` (the display's visible height less margins).
    static func resultsHeight(content: CGFloat, chrome: CGFloat, maxPanelHeight: CGFloat) -> CGFloat {
        let room = maxPanelHeight - topPadding - bottomPadding - chrome - spacing
        return max(0, min(content, resultsMaxHeight, max(resultsMinHeight, room)))
    }

    /// The panel's total height for a given chrome and results height (0 when there are no results).
    static func panelHeight(chrome: CGFloat, results: CGFloat) -> CGFloat {
        topPadding + chrome + (results > 0 ? spacing + results : 0) + bottomPadding
    }
}

extension Notification.Name {
    static let focusTranslateInput = Notification.Name("ShocrotFocusTranslateInput")
}
