import AppKit
import Combine
import SwiftUI

enum CaptureMode { case area, ocr }

/// What the user decided to do with a finished selection.
enum CaptureOutcome {
    case copy, save, saveAs, pin, ocr
}

/// The product of a finished selection.
struct CaptureResult {
    let image: CGImage      // with annotations
    let rawImage: CGImage   // without annotations (for OCR)
    let globalRect: CGRect  // AppKit global coordinates, in points
    let scale: CGFloat
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
    private let completion: (CaptureOutcome, CaptureResult) -> Void

    static var isActive: Bool { current != nil }

    static func start(mode: CaptureMode, snapshots: [ScreenSnapshot],
                      completion: @escaping (CaptureOutcome, CaptureResult) -> Void) {
        guard current == nil else { return }
        let session = CaptureSession(mode: mode, snapshots: snapshots, completion: completion)
        current = session
        session.show()
    }

    private init(mode: CaptureMode, snapshots: [ScreenSnapshot], completion: @escaping (CaptureOutcome, CaptureResult) -> Void) {
        self.mode = mode
        self.completion = completion
        let windows = ScreenCapturer.visibleWindows()
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

            let local = windows.compactMap { w -> CGRect? in
                let r = w.frame.offsetBy(dx: -snap.screen.frame.minX, dy: -snap.screen.frame.minY)
                    .intersection(CGRect(origin: .zero, size: snap.screen.frame.size))
                return r.isNull || r.width < 20 || r.height < 20 ? nil : r.integral
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
        for (panel, view) in zip(panels, views) {
            panel.orderFrontRegardless()
            if panel.frame.contains(mouse) {
                panel.makeKey()
                panel.makeFirstResponder(view)
                view.mouseLocation = view.convert(panel.convertPoint(fromScreen: mouse), from: nil)
                view.updateHover()
            }
        }
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
        close()
        // Let the overlay disappear before showing follow-up UI.
        DispatchQueue.main.async { self.completion(outcome, result) }
    }

    private func close() {
        views.forEach { $0.teardown() }
        panels.forEach { $0.orderOut(nil); $0.close() }
        panels.removeAll()
        views.removeAll()
        CaptureSession.current = nil
        NSCursor.arrow.set()
    }
}

final class OverlayView: NSView, NSTextFieldDelegate {
    private enum Phase {
        case idle
        case creating(start: CGPoint, dragged: Bool)
        case moving(anchor: CGPoint, original: CGRect)
        case resizing(handle: Handle, original: CGRect)
        case drawing
    }

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    }

    private let snapshot: ScreenSnapshot
    private let windowRects: [CGRect]
    private let mode: CaptureMode
    private weak var session: CaptureSession?
    private let state = OverlayState.shared
    private let scale: CGFloat

    private var phase: Phase = .idle
    private(set) var selection: CGRect?
    private var hoverRect: CGRect?
    var mouseLocation: CGPoint?
    private var annotations: [Annotation] = [] { didSet { syncUndoState() } }
    private var redoStack: [Annotation] = [] { didSet { syncUndoState() } }
    private var current: Annotation?
    private var textField: NSTextField?
    private var toolbarHost: NSHostingView<CaptureToolbar>?
    private var stateObserver: AnyCancellable?
    private var trackingArea: NSTrackingArea?
    private lazy var mosaicImage: CGImage? = snapshot.image.pixelated(blockSize: 9 * scale)
    private lazy var renderer = AnnotationRenderer(mosaicImage: { [weak self] in self?.mosaicImage }, backdropRect: bounds)

    init(frame: CGRect, snapshot: ScreenSnapshot, windowRects: [CGRect], mode: CaptureMode, session: CaptureSession) {
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
            DispatchQueue.main.async { self?.layoutToolbar(); self?.updateCursor() }
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
        hoverRect = nil
        mouseLocation = nil
        annotations.removeAll()
        redoStack.removeAll()
        phase = .idle
        toolbarHost?.removeFromSuperview()
        toolbarHost = nil
        needsDisplay = true
    }

    private func syncUndoState() {
        guard selection != nil else { return }
        state.canUndo = !annotations.isEmpty
        state.canRedo = !redoStack.isEmpty
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
            drawSelectionChrome(selection, in: ctx)
        } else if let hoverRect {
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(hoverRect.insetBy(dx: 1, dy: 1))
        }

        if showsMagnifier, let p = mouseLocation {
            drawMagnifier(at: p, in: ctx)
        }
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

    private func drawSelectionChrome(_ r: CGRect, in ctx: CGContext) {
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(r.insetBy(dx: -0.75, dy: -0.75))

        if case .creating = phase {} else if state.tool == nil || toolbarHost == nil {
            for h in Handle.allCases {
                let c = handleCenter(h, in: r)
                let dot = CGRect(x: c.x - 4.5, y: c.y - 4.5, width: 9, height: 9)
                ctx.setFillColor(NSColor.white.cgColor)
                ctx.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.4).cgColor)
                ctx.fillEllipse(in: dot)
                ctx.setShadow(offset: .zero, blur: 0, color: nil)
                ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: dot.insetBy(dx: 0.75, dy: 0.75))
            }
        }

        // Size badge (in pixels).
        let text = "\(Int(round(r.width * scale))) × \(Int(round(r.height * scale)))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        var badge = CGRect(x: r.minX, y: r.maxY + 6, width: size.width + 12, height: size.height + 6)
        if badge.maxY > bounds.maxY { badge.origin.y = r.maxY - badge.height - 6; badge.origin.x += 6 }
        badge.origin.x = min(badge.origin.x, bounds.maxX - badge.width - 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
        ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: badge.minX + 6, y: badge.minY + 3), withAttributes: attrs)
    }

    private func drawMagnifier(at p: CGPoint, in ctx: CGContext) {
        let cells = 15, zoom: CGFloat = 8
        let side = CGFloat(cells) * zoom
        let infoHeight: CGFloat = 44
        var origin = CGPoint(x: p.x + 22, y: p.y - 22 - side - infoHeight)
        if origin.x + side > bounds.maxX { origin.x = p.x - 22 - side }
        if origin.y < bounds.minY { origin.y = p.y + 22 }
        let lens = CGRect(x: origin.x, y: origin.y + infoHeight, width: side, height: side)
        let panel = CGRect(x: origin.x, y: origin.y, width: side, height: side + infoHeight)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 8, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setFillColor(NSColor(white: 0.1, alpha: 0.9).cgColor)
        ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.fillPath()
        ctx.restoreGState()

        // Pixel-accurate zoomed crop centered on the cursor pixel.
        let px = Int(p.x * scale), py = Int((bounds.height - p.y) * scale)
        let half = cells / 2
        let src = CGRect(x: px - half, y: py - half, width: cells, height: cells)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: lens, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(lens)
        let clipped = src.intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))
        if !clipped.isNull, let crop = snapshot.image.cropping(to: clipped) {
            ctx.interpolationQuality = .none
            let dest = CGRect(x: lens.minX + (clipped.minX - src.minX) * zoom,
                              y: lens.maxY - (clipped.maxY - src.minY) * zoom,
                              width: clipped.width * zoom, height: clipped.height * zoom)
            ctx.draw(crop, in: dest)
        }
        // Crosshair
        ctx.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor)
        let mid = CGFloat(half) * zoom
        ctx.fill(CGRect(x: lens.minX, y: lens.minY + mid, width: side, height: zoom))
        ctx.fill(CGRect(x: lens.minX + mid, y: lens.minY, width: zoom, height: side))
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(CGRect(x: lens.minX + mid, y: lens.minY + mid, width: zoom, height: zoom))
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: panel.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.strokePath()

        let color = pixelColor(at: p)
        let small: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let swatch = CGRect(x: panel.minX + 8, y: panel.minY + 8, width: 11, height: 11)
        ctx.setFillColor((color ?? .black).cgColor)
        ctx.fill(swatch)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.6).cgColor)
        ctx.stroke(swatch)
        ("\(color?.hexString ?? "-")  按 C 复制" as NSString)
            .draw(at: CGPoint(x: swatch.maxX + 6, y: panel.minY + 6), withAttributes: small)
        var info = "\(Int(p.x)), \(Int(bounds.height - p.y))"
        if let s = selection ?? (phaseIsCreating ? nil : hoverRect) {
            info = "\(Int(round(s.width * scale))) × \(Int(round(s.height * scale)))"
        }
        (info as NSString).draw(at: CGPoint(x: panel.minX + 8, y: panel.minY + 24), withAttributes: small)
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
        hoverRect = windowRects.first { $0.contains(p) }
        needsDisplay = true
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        mouseLocation = convert(event.locationInWindow, from: nil)
        if selection == nil { updateHover() } else if showsMagnifier { needsDisplay = true }
        updateCursor()
    }

    override func mouseExited(with event: NSEvent) {
        mouseLocation = nil
        if selection == nil { hoverRect = nil }
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
                hoverRect = nil
            }
        case let .moving(anchor, original):
            var r = original.offsetBy(dx: p.x - anchor.x, dy: p.y - anchor.y)
            r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
            r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
            shiftAnnotations(by: CGPoint(x: r.minX - (selection?.minX ?? r.minX), y: r.minY - (selection?.minY ?? r.minY)))
            selection = r.integral
        case let .resizing(h, o):
            var minX = o.minX, maxX = o.maxX, minY = o.minY, maxY = o.maxY
            switch h {
            case .topLeft: minX = p.x; maxY = p.y
            case .top: maxY = p.y
            case .topRight: maxX = p.x; maxY = p.y
            case .right: maxX = p.x
            case .bottomRight: maxX = p.x; minY = p.y
            case .bottom: minY = p.y
            case .bottomLeft: minX = p.x; minY = p.y
            case .left: minX = p.x
            }
            let r = rect(CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: maxY)).integral
            if r.width >= 2, r.height >= 2 { selection = r }
        case .drawing:
            updateAnnotation(to: p, constrained: event.modifierFlags.contains(.shift))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch phase {
        case let .creating(_, dragged):
            if !dragged {
                selection = hoverRect ?? bounds
            }
            phase = .idle
            if let s = selection, s.width < 4 || s.height < 4 { selection = nil; break }
            if selection != nil { selectionCompleted() }
        case .moving, .resizing:
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
                    annotations.append(a)
                    redoStack.removeAll()
                }
            }
            current = nil
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
        switch Settings.shared.afterCapture {
        case .copy: finish(.copy)
        case .save: finish(.save)
        case .edit: showToolbar()
        }
    }

    private func shiftAnnotations(by d: CGPoint) {
        guard d != .zero else { return }
        annotations = annotations.map { a in
            var a = a
            a.points = a.points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
            return a
        }
    }

    // MARK: - Annotations

    private func beginAnnotation(_ tool: Tool, at p: CGPoint) {
        switch tool {
        case .text:
            beginText(at: p)
        case .counter:
            let n = annotations.filter { $0.tool == .counter }.count + 1
            annotations.append(Annotation(tool: .counter, points: [p], color: state.color, width: state.width, number: n))
            redoStack.removeAll()
            needsDisplay = true
        default:
            let color = tool == .highlighter && state.color == OverlayState.palette[0] ? OverlayState.palette[2] : state.color
            current = Annotation(tool: tool, points: [p], color: color, width: state.width)
            phase = .drawing
        }
    }

    private func updateAnnotation(to p: CGPoint, constrained: Bool) {
        guard var a = current, let start = a.points.first else { return }
        switch a.tool {
        case .pen, .highlighter:
            a.points.append(p)
        case .arrow:
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
        annotations.append(Annotation(tool: .text, points: [origin], color: field.textColor ?? state.color,
                                      width: state.width, text: text))
        redoStack.removeAll()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        switch event.keyCode {
        case 53: session?.cancel(); return // Esc
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
            case "p": if selection != nil { finish(.pin) }
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
        switch keyCode {
        case 123: r.origin.x -= step
        case 124: r.origin.x += step
        case 125: r.origin.y -= step
        default: r.origin.y += step
        }
        r.origin.x = min(max(r.minX, 0), bounds.width - r.width)
        r.origin.y = min(max(r.minY, 0), bounds.height - r.height)
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
        guard let last = annotations.popLast() else { return }
        redoStack.append(last)
        needsDisplay = true
    }

    private func redo() {
        guard let a = redoStack.popLast() else { return }
        annotations.append(a)
        needsDisplay = true
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
        }
        syncUndoState()
        layoutToolbar()
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
        }
        window?.makeFirstResponder(self)
    }

    // MARK: - Export

    func makeResult() -> CaptureResult? {
        guard let sel = selection?.intersection(bounds), sel.width >= 1, sel.height >= 1 else { return nil }
        let pixelRect = CGRect(x: sel.minX * scale, y: (bounds.height - sel.maxY) * scale,
                               width: sel.width * scale, height: sel.height * scale).integral
        guard let raw = snapshot.image.cropping(to: pixelRect) else { return nil }
        var image = raw
        if !annotations.isEmpty,
           let ctx = CGContext(data: nil, width: raw.width, height: raw.height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: snapshot.image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            ctx.scaleBy(x: CGFloat(raw.width) / sel.width, y: CGFloat(raw.height) / sel.height)
            ctx.translateBy(x: -sel.minX, y: -sel.minY)
            ctx.interpolationQuality = .none
            ctx.draw(snapshot.image, in: bounds)
            annotations.forEach { renderer.draw($0, in: ctx) }
            image = ctx.makeImage() ?? raw
        }
        let global = sel.offsetBy(dx: snapshot.screen.frame.minX, dy: snapshot.screen.frame.minY)
        return CaptureResult(image: image, rawImage: raw, globalRect: global, scale: scale)
    }
}
