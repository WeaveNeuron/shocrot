import AppKit
import Combine
import SwiftUI

enum CaptureMode { case area, ocr, translate }

/// What the user decided to do with a finished selection.
enum CaptureOutcome {
    case copy, save, saveAs, pin, ocr, translate, scroll, record

    /// Whether the follow-up opens a window of ours that takes focus (the save panel, the OCR window).
    /// Handing focus back to the previous app first would race with that window's own activation.
    func opensFocusedWindow(ocrShowsWindow: Bool) -> Bool {
        switch self {
        case .saveAs: return true
        case .ocr: return ocrShowsWindow
        default: return false
        }
    }
}

/// The product of a finished selection.
struct CaptureResult {
    let image: CGImage      // with annotations
    let ocrImage: CGImage   // for OCR: no drawings on top of the text, but mosaics stay redacted
    let globalRect: CGRect  // AppKit global coordinates, in points
    let scale: CGFloat
}

/// A window the selection can snap to, in the overlay view's coordinates.
struct SnapWindow {
    let rect: CGRect
    let id: CGWindowID
    let pid: pid_t
}

/// Borderless, non-activating panel so we can take key events without stealing focus from the frontmost app.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Coordinates one capture across all displays.
final class CaptureSession {
    private(set) static var current: CaptureSession?

    let mode: CaptureMode
    private var panels: [OverlayPanel] = []
    private var views: [OverlayView] = []
    /// The app that had focus before the overlay took it, to give it back afterwards.
    private var previousApp: NSRunningApplication?
    private let completion: (CaptureOutcome, CaptureResult) -> Void
    /// ⌥-click on a window: capture that window on its own (after the overlay has closed).
    var onWindowCapture: ((CGWindowID, NSScreen?) -> Void)?

    static var isActive: Bool { current != nil }

    @discardableResult
    static func start(mode: CaptureMode, snapshots: [ScreenSnapshot], windows: [WindowInfo],
                      completion: @escaping (CaptureOutcome, CaptureResult) -> Void) -> CaptureSession? {
        guard current == nil else { return nil }
        let session = CaptureSession(mode: mode, snapshots: snapshots, windows: windows, completion: completion)
        current = session
        session.show()
        return session
    }

    private init(mode: CaptureMode, snapshots: [ScreenSnapshot], windows: [WindowInfo],
                 completion: @escaping (CaptureOutcome, CaptureResult) -> Void) {
        self.mode = mode
        self.completion = completion
        for snap in snapshots {
            let panel = OverlayPanel(contentRect: snap.screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                     backing: .buffered, defer: false)
            panel.level = .screenSaver
            panel.isOpaque = true
            panel.hasShadow = false
            panel.backgroundColor = .black
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isReleasedWhenClosed = false
            panel.acceptsMouseMovedEvents = true
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.setFrame(snap.screen.frame, display: false)

            let local = windows.compactMap { w -> SnapWindow? in
                let r = w.frame.offsetBy(dx: -snap.screen.frame.minX, dy: -snap.screen.frame.minY)
                    .intersection(CGRect(origin: .zero, size: snap.screen.frame.size))
                return r.isNull || r.width < 20 || r.height < 20 ? nil : SnapWindow(rect: r.integral, id: w.id, pid: w.pid)
            }
            let container = NSView(frame: CGRect(origin: .zero, size: snap.screen.frame.size))
            container.wantsLayer = true
            container.layer?.contents = snap.image
            container.layer?.contentsGravity = .resize
            let view = OverlayView(frame: container.bounds, snapshot: snap, windowRects: local, mode: mode, session: self)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            panel.contentView = container
            panels.append(panel)
            views.append(view)
        }
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        // A key panel of an inactive app gets no keystrokes until it is clicked, so Esc, C and ⌘A
        // would go to the app underneath. The overlay covers every screen, so the switch is invisible.
        if !NSApp.isActive {
            previousApp = NSWorkspace.shared.frontmostApplication
            NSApp.activate()
        }
        for (panel, view) in zip(panels, views) {
            // The frozen backdrop matches the screen, so only the dimming layer fades in.
            view.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.16
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
            if panel.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
                view.mouseLocation = view.convert(panel.convertPoint(fromScreen: mouse), from: nil)
                view.updateHover()
            }
        }
        // Commit now instead of at the end of the run loop pass: the overlay appears ~40 ms sooner.
        CATransaction.flush()
        NSCursor.crosshair.set()
    }

    /// Called by a view that starts a new selection; other displays drop theirs.
    func activate(_ view: OverlayView) {
        for v in views where v !== view { v.reset() }
        if let panel = view.window, !panel.isKeyWindow {
            panel.makeKey()
            panel.makeFirstResponder(view)
        }
    }

    func cancel() {
        close()
    }

    func finish(_ outcome: CaptureOutcome, from view: OverlayView) {
        guard let result = view.makeResult() else { cancel(); return }
        close(restoringFocus: !outcome.opensFocusedWindow(ocrShowsWindow: Settings.shared.ocrShowWindow))
        // Let the overlay disappear before showing follow-up UI.
        DispatchQueue.main.async { self.completion(outcome, result) }
    }

    func captureWindow(_ window: SnapWindow, from view: OverlayView) {
        let screen = view.window?.screen
        close()
        DispatchQueue.main.async { self.onWindowCapture?(window.id, screen) }
    }

    /// Offered at most once per launch, and only to someone who just reached for the feature.
    private static var offeredAccessibility = false

    private func close(restoringFocus: Bool = true) {
        if views.contains(where: \.wheelNeedsAccess), !Self.offeredAccessibility {
            Self.offeredAccessibility = true
            // After the overlay and whatever follows the capture (the preview card) are up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Feedback.offer("开启“辅助功能”后，截图时可用滚轮选中窗口里的控件",
                               symbol: "cursorarrow.rays", action: "开启") {
                    MainActor.assumeIsolated { Permission.accessibility.request() }
                }
            }
        }
        views.forEach { $0.teardown() }
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        views.removeAll()
        CaptureSession.current = nil
        NSCursor.arrow.set()
        if !restoringFocus {
            FocusReturn.remember(previousApp)
        } else if let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }
}

final class OverlayView: NSView, NSTextFieldDelegate {
    private enum Phase {
        case idle
        case creating(start: CGPoint, dragged: Bool)
        case moving(anchor: CGPoint, original: CGRect)
        case resizing(handle: Handle, original: CGRect)
        case drawing
        case movingAnnotation(index: Int, anchor: CGPoint, original: Annotation, moved: Bool)
    }

    private typealias Handle = SelectionHandle

    private let snapshot: ScreenSnapshot
    private let windowRects: [SnapWindow]
    private var hoverWindow: SnapWindow?
    /// How far into the hovered window the snap goes: 0 is the whole window, each wheel step one element further in.
    private var snapDepth = 0
    /// Element frames around the pointer, innermost first and the window last (empty until probed).
    private var snapLevels: [CGRect] = []
    private var scrollAccumulator: CGFloat = 0
    /// The wheel was used without Accessibility access, so the hover badge says what is missing.
    private(set) var wheelNeedsAccess = false
    private let mode: CaptureMode
    private weak var session: CaptureSession?
    private let state = OverlayState.shared
    private let scale: CGFloat

    private var phase: Phase = .idle
    private(set) var selection: CGRect?
    private var hoverRect: CGRect?
    var mouseLocation: CGPoint?
    private var annotations: [Annotation] = []
    private var history = AnnotationHistory() { didSet { syncUndoState() } }
    private var selectedAnnotation: Int? { didSet { if oldValue != selectedAnnotation { needsDisplay = true } } }
    private var current: Annotation?
    private var textField: NSTextField?
    private var toolbarHost: NSHostingView<CaptureToolbar>?
    private var stateObserver: AnyCancellable?
    private var trackingArea: NSTrackingArea?
    private var pendingHistoryShift = CGPoint.zero
    private lazy var mosaic = MosaicSource(source: snapshot.image, blockSize: 9 * scale)
    private lazy var renderer = AnnotationRenderer(mosaicImage: { [weak self] in self?.mosaic.get() }, backdropRect: bounds)

    init(frame: CGRect, snapshot: ScreenSnapshot, windowRects: [SnapWindow], mode: CaptureMode, session: CaptureSession) {
        self.snapshot = snapshot
        self.windowRects = windowRects
        self.mode = mode
        self.session = session
        self.scale = CGFloat(snapshot.image.width) / frame.width
        super.init(frame: frame)
        state.canUndo = false
        state.canRedo = false
        state.tool = nil
        stateObserver = state.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.layoutToolbar(); self?.updateCursor(); self?.prepareMosaicIfPicked() }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    func teardown() {
        stateObserver = nil
        textField?.removeFromSuperview()
        toolbarHost?.removeFromSuperview()
    }

    func reset() {
        commitText()
        selection = nil
        hoverRect = nil; hoverWindow = nil
        snapDepth = 0
        snapLevels = []
        mouseLocation = nil
        annotations.removeAll()
        history.removeAll()
        pendingHistoryShift = .zero
        selectedAnnotation = nil
        phase = .idle
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        needsDisplay = true
    }

    private func prepareMosaicIfPicked() {
        if state.tool == .mosaic, toolbarHost != nil { mosaic.prepare() }
    }

    private func syncUndoState() {
        guard selection != nil else { return }
        state.canUndo = history.canUndo
        state.canRedo = history.canRedo
    }

    private func pushUndo() {
        applyPendingHistoryShift()
        history.record(annotations)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let focus = selection ?? hoverRect

        // Dim everything outside the focus rectangle.
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let focus {
            ctx.addRect(bounds)
            ctx.addRect(focus)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }

        if let selection {
            ctx.saveGState()
            ctx.clip(to: selection)
            annotations.forEach { renderer.draw($0, in: ctx) }
            if let current { renderer.draw(current, in: ctx) }
            ctx.restoreGState()
            if let i = selectedAnnotation, annotations.indices.contains(i) {
                let r = frame(of: annotations[i]).insetBy(dx: -5, dy: -5)
                ctx.saveGState()
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                ctx.setLineWidth(1)
                ctx.setLineDash(phase: 0, lengths: [4, 3])
                ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.strokePath()
                ctx.restoreGState()
            }
            drawSelectionChrome(selection, in: ctx)
        } else if let hoverRect {
            ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.06).cgColor)
            ctx.fill(hoverRect)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(hoverRect.insetBy(dx: 1, dy: 1))
            if !phaseIsCreating { drawBadge(hoverBadgeText(for: hoverRect), above: hoverRect, in: ctx) }
        }

        if showsGuides, let p = mouseLocation { drawGuides(at: p, in: ctx) }
        if showsMagnifier, let p = mouseLocation { drawMagnifier(at: p, in: ctx) }
    }

    private var showsMagnifier: Bool {
        guard Settings.shared.showMagnifier else { return false }
        switch phase {
        case .idle: return selection == nil
        case .creating: return true
        case .resizing: return true
        default: return false
        }
    }

    private var showsGuides: Bool {
        if case .idle = phase { return selection == nil }
        if case let .creating(_, dragged) = phase { return !dragged }
        return false
    }

    /// Full-screen hairlines through the cursor for precise alignment.
    private func drawGuides(at p: CGPoint, in ctx: CGContext) {
        let x = (p.x * scale).rounded(.down) / scale + 0.5 / scale
        let y = (p.y * scale).rounded(.down) / scale + 0.5 / scale
        ctx.saveGState()
        ctx.setLineWidth(1 / scale)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.45).cgColor)
        ctx.setShadow(offset: .zero, blur: 1, color: NSColor.black.withAlphaComponent(0.35).cgColor)
        ctx.strokeLineSegments(between: [CGPoint(x: bounds.minX, y: y), CGPoint(x: bounds.maxX, y: y),
                                         CGPoint(x: x, y: bounds.minY), CGPoint(x: x, y: bounds.maxY)])
        ctx.restoreGState()
    }

    private func drawSelectionChrome(_ r: CGRect, in ctx: CGContext) {
        // Crisp hairline frame with a faint dark halo so it reads on light and dark content.
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(r.insetBy(dx: -1.5, dy: -1.5))
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r.insetBy(dx: -0.5, dy: -0.5))
        ctx.restoreGState()

        if case .creating = phase {} else if state.tool == nil || toolbarHost == nil {
            for h in Handle.allCases {
                let c = handleCenter(h, in: r)
                let dot = CGRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 2.5, color: NSColor.black.withAlphaComponent(0.45).cgColor)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.fillEllipse(in: dot)
                ctx.restoreGState()
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.25)
                ctx.strokeEllipse(in: dot.insetBy(dx: 0.6, dy: 0.6))
            }
        }

        drawBadge("\(Int(round(r.width * scale))) × \(Int(round(r.height * scale)))", above: r, in: ctx)
    }

    /// Size of the hovered window or element, plus what a click can do with it.
    private func hoverBadgeText(for r: CGRect) -> String {
        var parts = ["\(Int(round(r.width * scale))) × \(Int(round(r.height * scale)))"]
        if wheelNeedsAccess {
            parts.append("滚轮选择控件需要“辅助功能”权限")
        } else if snapDepth == 0, mode == .area {
            parts.append("⌥单击 单独截取窗口")
        }
        return parts.joined(separator: "  ·  ")
    }

    /// A small dark pill just above `r` (inside it when there is no room), e.g. the selection size.
    private func drawBadge(_ text: String, above r: CGRect, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.roundedMonospaced(size: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var badge = CGRect(x: r.minX, y: r.maxY + 8, width: ceil(size.width) + 14, height: 20)
        if badge.maxY > bounds.maxY - 2 { badge.origin = CGPoint(x: r.minX + 8, y: r.maxY - badge.height - 8) }
        badge.origin.x = min(max(badge.origin.x, 4), bounds.maxX - badge.width - 4)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 4, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setFillColor(NSColor(white: 0.08, alpha: 0.82).cgColor)
        ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()
        (text as NSString).draw(at: CGPoint(x: badge.minX + 7, y: badge.midY - size.height / 2), withAttributes: attrs)
    }

    private func drawMagnifier(at p: CGPoint, in ctx: CGContext) {
        let cells = 17, zoom: CGFloat = 7
        let side = CGFloat(cells) * zoom
        let infoHeight: CGFloat = 50
        let radius: CGFloat = 12
        var origin = CGPoint(x: p.x + 24, y: p.y - 24 - side - infoHeight)
        if origin.x + side > bounds.maxX - 4 { origin.x = p.x - 24 - side }
        if origin.y < bounds.minY + 4 { origin.y = p.y + 24 }
        let panel = CGRect(x: origin.x, y: origin.y, width: side, height: side + infoHeight)
        let lens = CGRect(x: origin.x, y: origin.y + infoHeight, width: side, height: side)

        // Card
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor(white: 0.09, alpha: 0.94).cgColor)
        ctx.addPath(CGPath(roundedRect: panel, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Pixel-accurate zoomed crop centered on the cursor pixel.
        let px = Int(p.x * scale), py = Int((bounds.height - p.y) * scale)
        let half = cells / 2
        let src = CGRect(x: px - half, y: py - half, width: cells, height: cells)
        ctx.saveGState()
        let lensPath = CGMutablePath()
        lensPath.addRoundedRect(in: lens, cornerWidth: radius, cornerHeight: radius)
        ctx.addPath(lensPath)
        ctx.addRect(CGRect(x: lens.minX, y: lens.minY, width: lens.width, height: radius)) // square bottom corners
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(lens)
        let clipped = src.intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        if !clipped.isNull, let crop = snapshot.image.cropping(to: clipped) {
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: CGRect(x: lens.minX + (clipped.minX - src.minX) * zoom,
                                      y: lens.maxY - (clipped.maxY - src.minY) * zoom,
                                      width: clipped.width * zoom, height: clipped.height * zoom))
        }
        // Pixel grid
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<cells {
            let o = CGFloat(i) * zoom
            ctx.strokeLineSegments(between: [CGPoint(x: lens.minX + o, y: lens.minY), CGPoint(x: lens.minX + o, y: lens.maxY),
                                             CGPoint(x: lens.minX, y: lens.minY + o), CGPoint(x: lens.maxX, y: lens.minY + o)])
        }
        // Crosshair band + center pixel
        let mid = CGFloat(half) * zoom
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor)
        ctx.fill(CGRect(x: lens.minX, y: lens.minY + mid, width: mid, height: zoom))
        ctx.fill(CGRect(x: lens.minX + mid + zoom, y: lens.minY + mid, width: mid, height: zoom))
        ctx.fill(CGRect(x: lens.minX + mid, y: lens.minY, width: zoom, height: mid))
        ctx.fill(CGRect(x: lens.minX + mid, y: lens.minY + mid + zoom, width: zoom, height: mid))
        let center = CGRect(x: lens.minX + mid, y: lens.minY + mid, width: zoom, height: zoom)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.stroke(center.insetBy(dx: -1, dy: -1))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.stroke(center)
        ctx.restoreGState()

        // Hairline border + divider
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.16).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.strokePath()
        ctx.strokeLineSegments(between: [CGPoint(x: lens.minX, y: lens.minY), CGPoint(x: lens.maxX, y: lens.minY)])

        // Info: color + position/size
        let color = pixelColor(at: p)
        let primary: [NSAttributedString.Key: Any] = [
            .font: NSFont.roundedMonospaced(size: 11, weight: .semibold), .foregroundColor: NSColor.white,
        ]
        let secondary: [NSAttributedString.Key: Any] = [
            .font: NSFont.roundedMonospaced(size: 10, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]
        let swatch = CGRect(x: panel.minX + 10, y: panel.minY + 28, width: 12, height: 12)
        ctx.setFillColor((color ?? .black).cgColor)
        ctx.addPath(CGPath(roundedRect: swatch, cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.5).cgColor)
        ctx.addPath(CGPath(roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.strokePath()
        ((color?.hexString ?? "—") as NSString).draw(at: CGPoint(x: swatch.maxX + 6, y: swatch.minY - 1), withAttributes: primary)
        // "C" keycap hint: press C to copy the color.
        let cap = CGRect(x: panel.maxX - 26, y: swatch.minY - 1, width: 16, height: 14)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        ctx.strokePath()
        let c = "C" as NSString
        let cs = c.size(withAttributes: secondary)
        c.draw(at: CGPoint(x: cap.midX - cs.width / 2, y: cap.midY - cs.height / 2), withAttributes: secondary)
        var info = "\(Int(p.x)), \(Int(bounds.height - p.y))"
        if let s = selection ?? (phaseIsCreating ? nil : hoverRect) {
            info = "\(Int(round(s.width * scale))) × \(Int(round(s.height * scale)))"
        }
        (info as NSString).draw(at: CGPoint(x: panel.minX + 10, y: panel.minY + 9), withAttributes: secondary)
    }

    private var phaseIsCreating: Bool {
        if case .creating = phase { return true }
        return false
    }

    private func pixelColor(at p: CGPoint) -> NSColor? {
        let px = Int(p.x * scale), py = Int((bounds.height - p.y) * scale)
        guard px >= 0, py >= 0, px < snapshot.image.width, py < snapshot.image.height,
              let crop = snapshot.image.cropping(to: CGRect(x: px, y: py, width: 1, height: 1)) else { return nil }
        return NSBitmapImageRep(cgImage: crop).colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB)
    }

    // MARK: - Geometry helpers

    private func handleCenter(_ h: Handle, in r: CGRect) -> CGPoint {
        switch h {
        case .topLeft: return CGPoint(x: r.minX, y: r.maxY)
        case .top: return CGPoint(x: r.midX, y: r.maxY)
        case .topRight: return CGPoint(x: r.maxX, y: r.maxY)
        case .right: return CGPoint(x: r.maxX, y: r.midY)
        case .bottomRight: return CGPoint(x: r.maxX, y: r.minY)
        case .bottom: return CGPoint(x: r.midX, y: r.minY)
        case .bottomLeft: return CGPoint(x: r.minX, y: r.minY)
        case .left: return CGPoint(x: r.minX, y: r.midY)
        }
    }

    private func handle(at p: CGPoint) -> Handle? {
        guard let selection, annotations.isEmpty || state.tool == nil else { return nil }
        return Handle.allCases.first { h in
            let c = handleCenter(h, in: selection)
            return abs(c.x - p.x) <= 7 && abs(c.y - p.y) <= 7
        }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            .intersection(bounds)
    }

    private func clamp(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(max(p.x, bounds.minX), bounds.maxX), y: min(max(p.y, bounds.minY), bounds.maxY))
    }

    func updateHover() {
        guard selection == nil, let p = mouseLocation else { return }
        let window = windowRects.first { $0.rect.contains(p) }
        if window?.id != hoverWindow?.id { snapLevels = [] }
        hoverWindow = window
        applySnapDepth()
        if snapDepth > 0 { probeElements(at: p) }
    }

    private func applySnapDepth() {
        if let w = hoverWindow, snapDepth > 0, snapLevels.last == w.rect {
            hoverRect = snapLevels[max(0, snapLevels.count - 1 - snapDepth)]
        } else {
            hoverRect = hoverWindow?.rect
        }
        needsDisplay = true
    }

    /// Asks the hovered app which elements are under the pointer; the answer arrives asynchronously.
    private func probeElements(at p: CGPoint) {
        guard let w = hoverWindow, ElementProbe.isAvailable else { return }
        let screen = snapshot.screen.frame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let global = CGPoint(x: screen.minX + p.x, y: primaryHeight - (screen.minY + p.y))
        ElementProbe.shared.frames(at: global, pid: w.pid) { [weak self] frames in
            guard let self, self.selection == nil, self.hoverWindow?.id == w.id else { return }
            let local = frames.map {
                CGRect(x: $0.minX - screen.minX, y: primaryHeight - $0.maxY - screen.minY, width: $0.width, height: $0.height)
            }
            self.snapLevels = ElementProbe.levels(local, window: w.rect)
            self.snapDepth = min(self.snapDepth, self.snapLevels.count - 1)
            self.applySnapDepth()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard selection == nil, hoverWindow != nil, let p = mouseLocation, event.momentumPhase.isEmpty else { return }
        var step = 0
        if event.hasPreciseScrollingDeltas {
            scrollAccumulator += event.scrollingDeltaY
            if abs(scrollAccumulator) >= 14 { step = scrollAccumulator > 0 ? 1 : -1; scrollAccumulator = 0 }
        } else if event.scrollingDeltaY != 0 {
            step = event.scrollingDeltaY > 0 ? 1 : -1
        }
        guard step != 0 else { return }
        guard ElementProbe.isAvailable else {
            wheelNeedsAccess = true
            needsDisplay = true
            return
        }
        // Until the elements are known, allow one step in; the answer clamps it.
        let deepest = snapLevels.last == hoverWindow?.rect ? snapLevels.count - 1 : 1
        snapDepth = min(max(snapDepth + step, 0), deepest)
        applySnapDepth()
        if snapDepth > 0 { probeElements(at: p) }
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if selection == nil { updateHover() } else if showsMagnifier { needsDisplay = true }
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        if selection == nil { hoverRect = nil; hoverWindow = nil }
        needsDisplay = true
    }

    private func updateCursor() {
        guard let p = mouseLocation else { return }
        guard let selection else { NSCursor.crosshair.set(); return }
        if let h = handle(at: p) {
            switch h {
            case .left, .right: NSCursor.resizeLeftRight.set()
            case .top, .bottom: NSCursor.resizeUpDown.set()
            default: NSCursor.crosshair.set()
            }
        } else if selection.contains(p), annotationIndex(at: p) != nil {
            NSCursor.openHand.set()
        } else if selection.contains(p) {
            switch state.tool {
            case .none: NSCursor.openHand.set()
            case .text: NSCursor.iBeam.set()
            default: NSCursor.crosshair.set()
            }
        } else {
            NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseLocation = p
        let hadText = textField != nil
        commitText()

        guard let selection else {
            session?.activate(self)
            phase = .creating(start: p, dragged: false)
            return
        }
        if let h = handle(at: p) {
            phase = .resizing(handle: h, original: selection)
            hideToolbar()
            return
        }
        if selection.contains(p) {
            if !hadText, let i = annotationIndex(at: p) {
                selectedAnnotation = i
                phase = .movingAnnotation(index: i, anchor: p, original: annotations[i], moved: false)
                NSCursor.closedHand.set()
                return
            }
            selectedAnnotation = nil
            if let tool = state.tool {
                if hadText && tool == .text { return } // click just ends the edit
                beginAnnotation(tool, at: p)
            } else if event.clickCount == 2 {
                finish(.copy)
            } else {
                phase = .moving(anchor: p, original: selection)
                NSCursor.closedHand.set()
                hideToolbar()
            }
            return
        }
        // Outside the selection: start over if nothing has been drawn yet.
        if annotations.isEmpty {
            session?.activate(self)
            self.selection = nil
            hideToolbar()
            phase = .creating(start: p, dragged: false)
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = clamp(convert(event.locationInWindow, from: nil))
        mouseLocation = p
        switch phase {
        case .idle:
            break
        case let .creating(start, dragged):
            if dragged || hypot(p.x - start.x, p.y - start.y) > 3 {
                phase = .creating(start: start, dragged: true)
                var end = p
                if event.modifierFlags.contains(.shift) { // square
                    let side = max(abs(p.x - start.x), abs(p.y - start.y))
                    end = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
                }
                selection = rect(start, end).integral
                hoverRect = nil; hoverWindow = nil
            }
        case let .moving(anchor, original):
            let r = SelectionGeometry.clamped(original.offsetBy(dx: p.x - anchor.x, dy: p.y - anchor.y), in: bounds)
            shiftAnnotations(by: CGPoint(x: r.minX - (selection?.minX ?? r.minX), y: r.minY - (selection?.minY ?? r.minY)))
            selection = r.integral
        case let .resizing(h, o):
            if let r = SelectionGeometry.resized(o, handle: h, to: p, in: bounds) { selection = r }
        case .drawing:
            updateAnnotation(to: p, constrained: event.modifierFlags.contains(.shift))
        case let .movingAnnotation(i, anchor, original, moved):
            guard annotations.indices.contains(i) else { break }
            if !moved {
                pushUndo()
                phase = .movingAnnotation(index: i, anchor: anchor, original: original, moved: true)
            }
            let dx = p.x - anchor.x, dy = p.y - anchor.y
            annotations[i].points = original.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case let .creating(_, dragged):
            if !dragged, mode == .area, event.modifierFlags.contains(.option), let w = hoverWindow {
                phase = .idle
                session?.captureWindow(w, from: self)
                return
            }
            if !dragged {
                selection = hoverRect ?? bounds
            }
            phase = .idle
            if let s = selection, s.width < 4 || s.height < 4 { selection = nil; break }
            if selection != nil { selectionCompleted() }
        case .moving, .resizing:
            applyPendingHistoryShift()
            phase = .idle
            showToolbar()
        case .drawing:
            phase = .idle
            if var a = current {
                let r = a.boundingRect
                let meaningful = a.tool == .counter || a.tool == .text || r.width > 2 || r.height > 2
                if a.tool == .pen || a.tool == .highlighter, a.points.count == 1 {
                    a.points.append(CGPoint(x: a.points[0].x + 0.1, y: a.points[0].y)) // a dot
                }
                if meaningful || a.tool == .pen || a.tool == .highlighter {
                    pushUndo()
                    annotations.append(a)
                }
            }
            current = nil
        case .movingAnnotation:
            phase = .idle
        case .idle:
            break
        }
        needsDisplay = true
        updateCursor()
    }

    override func rightMouseDown(with event: NSEvent) {
        // Right click steps back: drop the selection first, then cancel.
        if selection != nil {
            reset()
            updateHover()
        } else {
            session?.cancel()
        }
    }

    private func selectionCompleted() {
        if mode == .ocr { finish(.ocr); return }
        if mode == .translate { finish(.translate); return }
        switch Settings.shared.afterCapture {
        case .copy: finish(.copy)
        case .save: finish(.save)
        case .edit: showToolbar()
        }
    }

    private func shiftAnnotations(by d: CGPoint) {
        guard d != .zero else { return }
        annotations = annotations.map { $0.shifted(by: d) }
        pendingHistoryShift.x += d.x
        pendingHistoryShift.y += d.y
    }

    /// Rewriting all of history on every drag event is wasteful, so it catches up when the result is needed.
    private func applyPendingHistoryShift() {
        guard pendingHistoryShift != .zero else { return }
        history.shift(by: pendingHistoryShift)
        pendingHistoryShift = .zero
    }

    // MARK: - Annotations

    private func beginAnnotation(_ tool: Tool, at p: CGPoint) {
        switch tool {
        case .text:
            beginText(at: p)
        case .counter:
            let n = annotations.filter { $0.tool == .counter }.count + 1
            pushUndo()
            annotations.append(Annotation(tool: .counter, points: [p], color: state.color, width: state.width, number: n))
            needsDisplay = true
        default:
            let color = tool == .highlighter && state.color == OverlayState.palette[0] ? OverlayState.palette[2] : state.color
            current = Annotation(tool: tool, points: [p], color: color, width: state.width, pixelScale: scale)
            phase = .drawing
        }
    }

    private func updateAnnotation(to p: CGPoint, constrained: Bool) {
        guard var a = current, let start = a.points.first else { return }
        switch a.tool {
        case .pen, .highlighter:
            a.points.append(p)
        case .arrow, .ruler:
            var end = p
            if constrained { // snap to 45°
                let angle = (atan2(p.y - start.y, p.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
                let len = hypot(p.x - start.x, p.y - start.y)
                end = CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
            }
            a.points = [start, end]
        default:
            var end = p
            if constrained {
                let side = max(abs(p.x - start.x), abs(p.y - start.y))
                end = CGPoint(x: start.x + (p.x >= start.x ? side : -side), y: start.y + (p.y >= start.y ? side : -side))
            }
            a.points = [start, end]
        }
        current = a
    }

    private func beginText(at p: CGPoint) {
        let field = NSTextField(string: "")
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = Annotation.font(for: state.width)
        field.textColor = state.color
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.placeholderString = "输入文字"
        let height = ceil(field.font!.boundingRectForFont.height) + 4
        field.frame = CGRect(x: p.x - 2, y: p.y - height / 2, width: 160, height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        let width = (field.stringValue as NSString).size(withAttributes: [.font: field.font!]).width + 24
        field.frame.size.width = max(160, width)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(insertNewline(_:)) {
            commitText()
            window?.makeFirstResponder(self)
            return true
        }
        if selector == #selector(cancelOperation(_:)) {
            textField?.removeFromSuperview()
            textField = nil
            window?.makeFirstResponder(self)
            return true
        }
        return false
    }

    private func commitText() {
        guard let field = textField else { return }
        textField = nil
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        guard !text.isEmpty else { return }
        let origin = CGPoint(x: field.frame.minX + 2, y: field.frame.maxY - 2)
        pushUndo()
        annotations.append(Annotation(tool: .text, points: [origin], color: field.textColor ?? state.color,
                                      width: state.width, text: text))
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53: // Esc: deselect first, then cancel
            if selectedAnnotation != nil { selectedAnnotation = nil } else { session?.cancel() }
            return
        case 51, 117: deleteSelectedAnnotation(); return // Delete
        case 36, 76: if selection != nil { finish(.copy) }; return // Return / Enter
        case 123, 124, 125, 126:
            nudge(keyCode: event.keyCode, by: flags.contains(.shift) ? 10 : 1)
            return
        default: break
        }

        if flags == .command {
            switch key {
            case "c": if selection != nil { finish(.copy) }
            case "s": if selection != nil { finish(.save) }
            case "t": if selection != nil { finish(.ocr) }
            case "d": if selection != nil { finish(.translate) }
            case "p": if selection != nil { finish(.pin) }
            case "l": if selection != nil { finish(.scroll) }
            case "r": if selection != nil { finish(.record) }
            case "z": undo()
            case "a": selectAll()
            default: break
            }
            return
        }
        if flags == [.command, .shift] {
            if key == "z" { redo() }
            if key == "s", selection != nil { finish(.saveAs) }
            return
        }
        guard flags.isEmpty || flags == .shift else { return }

        if selection == nil {
            if key == "c", let p = mouseLocation, let color = pixelColor(at: p) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(color.hexString, forType: .string)
                Feedback.toast("已复制颜色 \(color.hexString)")
                session?.cancel()
            }
            return
        }
        if mode == .area, toolbarHost != nil, let c = key.first, let tool = Tool.allCases.first(where: { $0.shortcut == c }) {
            state.tool = state.tool == tool ? nil : tool
        }
    }

    private func nudge(keyCode: UInt16, by step: CGFloat) {
        guard var r = selection, annotations.isEmpty else { return }
        let before = r.origin
        switch keyCode {
        case 123: r.origin.x -= step
        case 124: r.origin.x += step
        case 125: r.origin.y -= step
        default: r.origin.y += step
        }
        r = SelectionGeometry.clamped(r, in: bounds)
        history.shift(by: CGPoint(x: r.minX - before.x, y: r.minY - before.y)) // undone annotations travel too
        selection = r
        layoutToolbar()
        needsDisplay = true
    }

    private func selectAll() {
        guard annotations.isEmpty else { return }
        session?.activate(self)
        selection = bounds
        selectionCompleted()
        needsDisplay = true
    }

    private func undo() {
        applyPendingHistoryShift()
        guard let previous = history.undo(from: annotations) else { return }
        annotations = previous
        selectedAnnotation = nil
        needsDisplay = true
    }

    private func redo() {
        applyPendingHistoryShift()
        guard let next = history.redo(from: annotations) else { return }
        annotations = next
        selectedAnnotation = nil
        needsDisplay = true
    }

    private func deleteSelectedAnnotation() {
        guard let i = selectedAnnotation, annotations.indices.contains(i) else { return }
        pushUndo()
        annotations.remove(at: i)
        selectedAnnotation = nil
        needsDisplay = true
    }

    // MARK: - Annotation hit testing

    private func frame(of a: Annotation) -> CGRect {
        switch a.tool {
        case .text:
            guard let p = a.points.first else { return .zero }
            let size = NSAttributedString(string: a.text, attributes: Annotation.textAttributes(color: a.color, width: a.width)).size()
            return CGRect(x: p.x, y: p.y - size.height, width: size.width, height: size.height)
        case .counter:
            guard let p = a.points.first else { return .zero }
            let d = 14 + a.width * 4
            return CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
        case .ruler:
            return a.boundingRect.insetBy(dx: -30, dy: -14) // room for the end ticks and the label
        default:
            let pad = a.tool == .highlighter ? a.width * 2.5 : a.width / 2
            return a.boundingRect.insetBy(dx: -pad, dy: -pad)
        }
    }

    private func annotationIndex(at p: CGPoint) -> Int? {
        annotations.indices.reversed().first { hits(annotations[$0], p) }
    }

    private func hits(_ a: Annotation, _ p: CGPoint) -> Bool {
        let tol = max(6, a.width + 3)
        switch a.tool {
        case .text, .counter, .mosaic:
            return frame(of: a).insetBy(dx: -3, dy: -3).contains(p)
        case .rect:
            let r = a.boundingRect
            return r.insetBy(dx: -tol, dy: -tol).contains(p) && !r.insetBy(dx: tol, dy: tol).contains(p)
        case .ellipse:
            let r = a.boundingRect
            guard r.width > 1, r.height > 1 else { return false }
            let rx = r.width / 2, ry = r.height / 2
            let v = hypot((p.x - r.midX) / rx, (p.y - r.midY) / ry)
            return abs(v - 1) * min(rx, ry) < tol
        case .arrow, .pen, .highlighter, .ruler:
            let t = a.tool == .highlighter ? a.width * 2.5 + 3 : tol
            return zip(a.points, a.points.dropFirst()).contains { distance(p, $0, $1) < t }
        }
    }

    private func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func finish(_ outcome: CaptureOutcome) {
        commitText()
        session?.finish(outcome, from: self)
    }

    // MARK: - Toolbar

    private func showToolbar() {
        guard selection != nil, mode == .area else { return }
        if toolbarHost == nil {
            let host = NSHostingView(rootView: CaptureToolbar(state: state, showsAnnotationTools: true) { [weak self] action in
                self?.handle(action)
            })
            addSubview(host)
            toolbarHost = host
            syncUndoState()
            layoutToolbar()
            // Rise-and-fade entrance.
            host.alphaValue = 0
            let final = host.frame
            host.setFrameOrigin(CGPoint(x: final.minX, y: final.minY - 6))
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                host.animator().alphaValue = 1
                host.animator().setFrameOrigin(final.origin)
            }
        } else {
            syncUndoState()
            layoutToolbar()
        }
        needsDisplay = true
    }

    private func hideToolbar() {
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
    }

    private func layoutToolbar() {
        guard let host = toolbarHost, let sel = selection else { return }
        let size = host.fittingSize
        let gap: CGFloat = 8
        var origin = CGPoint(x: sel.maxX - size.width, y: sel.minY - gap - size.height)
        if origin.y < 4 { // not enough room below: go above, else inside
            origin.y = sel.maxY + gap + 22
            if origin.y + size.height > bounds.maxY - 4 { origin.y = sel.minY + gap }
        }
        origin.x = min(max(origin.x, 4), bounds.maxX - size.width - 4)
        host.frame = CGRect(origin: origin, size: size)
    }

    private func handle(_ action: ToolbarAction) {
        switch action {
        case .undo: undo()
        case .redo: redo()
        case .cancel: session?.cancel()
        case .copy: finish(.copy)
        case .save: finish(.save)
        case .saveAs: finish(.saveAs)
        case .pin: finish(.pin)
        case .ocr: finish(.ocr)
        case .translate: finish(.translate)
        case .scroll: finish(.scroll)
        case .record: finish(.record)
        }
        window?.makeFirstResponder(self)
    }

    // MARK: - Export

    func makeResult() -> CaptureResult? {
        guard let sel = selection?.intersection(bounds), sel.width >= 1, sel.height >= 1 else { return nil }
        let pixelRect = CGRect(x: sel.minX * scale, y: (bounds.height - sel.maxY) * scale,
                               width: sel.width * scale, height: sel.height * scale).integral
        guard let cropped = snapshot.image.cropping(to: pixelRect) else { return nil }
        let raw = cropped.width == snapshot.image.width && cropped.height == snapshot.image.height
            ? cropped : cropped.detachedCopy()
        // Failing is safer than handing over an image without the user's redactions.
        guard let image = annotations.isEmpty ? raw : render(annotations, over: raw, selection: sel) else { return nil }
        let mosaics = annotations.filter { $0.tool == .mosaic }
        guard let ocrImage = mosaics.isEmpty ? raw : render(mosaics, over: raw, selection: sel) else { return nil }
        let global = sel.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
        return CaptureResult(image: image, ocrImage: ocrImage, globalRect: global, scale: scale)
    }

    private func render(_ list: [Annotation], over raw: CGImage, selection sel: CGRect) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: snapshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.scaleBy(x: CGFloat(raw.width) / sel.width, y: CGFloat(raw.height) / sel.height)
        ctx.translateBy(x: -sel.minX, y: -sel.minY)
        ctx.interpolationQuality = .none
        ctx.draw(snapshot.image, in: bounds)
        list.forEach { renderer.draw($0, in: ctx) }
        return ctx.makeImage()
    }
}
