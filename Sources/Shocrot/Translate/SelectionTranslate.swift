import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import os
import SwiftUI
import Translation

// MARK: - Pure Security & Geometry Policies (Unit-Testable)

/// Guards against showing selection translation inside password fields or while macOS Secure Input is active.
enum SelectionSecurity {
    static var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    /// Returns true when the element (or system state) represents a password or protected input.
    static func isProtected(role: String?, subrole: String?, roleDescription: String?, isSecureInputEnabled: Bool) -> Bool {
        if isSecureInputEnabled { return true }
        if role == "AXSecureTextField" || subrole == "AXSecureTextField" { return true }
        if let desc = roleDescription?.lowercased(),
           desc.contains("secure") || desc.contains("password") || desc.contains("密码") {
            return true
        }
        return false
    }
}

/// Pure coordinate conversion, drag-trigger, and placement logic for the selection translate icon and popover.
/// AppKit global coordinates have origin at the bottom-left of the primary display (y up);
/// CoreGraphics / Accessibility coordinates have origin at the top-left of the primary display (y down).
enum SelectionPopupLayout {
    static let margin: CGFloat = 8
    static let iconGap: CGFloat = 8
    static let iconVerticalGap: CGFloat = 6
    static let popoverGap: CGFloat = 8
    static let dragThreshold: CGFloat = 6
    static let iconSize = CGSize(width: 28, height: 28)
    static let iconCanvasInset: CGFloat = 10 // shadow breathing room around the floating icon
    static let adjacentLineClearanceLimit: CGFloat = 160
    static let popoverWidth: CGFloat = 320
    static let popoverMaxHeight: CGFloat = 280
    static let iconAutoDismissSeconds: TimeInterval = 4.5
    static let iconResumeDismissSeconds: TimeInterval = 2.0

    /// Converts an AX/CG rect (top-left origin relative to primary display) to AppKit global coordinates.
    static func cgRectToAppKit(_ rect: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Converts an AppKit global point (bottom-left origin) to AX/CG coordinates (top-left origin).
    static func appKitPointToCG(_ point: CGPoint, primaryScreenHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenHeight - point.y)
    }

    /// True when the mouse gesture could have created or changed a text selection (drag or double/triple-click).
    static func shouldTrigger(mouseDown: CGPoint, mouseUp: CGPoint, clickCount: Int) -> Bool {
        if clickCount >= 2 { return true }
        return hypot(mouseUp.x - mouseDown.x, mouseUp.y - mouseDown.y) >= dragThreshold
    }

    /// Extracts a valid non-empty trimmed selection suitable for translation, ignoring bare punctuation/whitespace.
    static func cleanedSelection(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4000 else { return nil }
        guard trimmed.unicodeScalars.contains(where: { $0.properties.isAlphabetic || CharacterSet.decimalDigits.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    /// Trims leading spaces/tabs and trailing whitespace/newlines from an AX line range (UTF-16 offsets)
    /// so `AXBoundsForRange` measures only the visible glyphs on that line and never spills onto the next line.
    static func trimmedLineRange(_ range: CFRange, text: String) -> CFRange? {
        let ns = text as NSString
        guard ns.length > 0, range.length > 0 else { return nil }
        var start = 0
        var end = min(ns.length, range.length)
        let leadingWS = CharacterSet(charactersIn: " \t")
        while start < end, let scalar = UnicodeScalar(ns.character(at: start)), leadingWS.contains(scalar) {
            start += 1
        }
        let trailingWS = CharacterSet.whitespacesAndNewlines
        while end > start, let scalar = UnicodeScalar(ns.character(at: end - 1)), trailingWS.contains(scalar) {
            end -= 1
        }
        guard end > start else { return nil }
        return CFRange(location: range.location + start, length: end - start)
    }

    /// Expands a line's horizontal clearance past ragged-edge adjacent lines (within `adjacentLineClearanceLimit`)
    /// whenever an icon vertically centered on `line` would vertically overlap those neighbors, and optionally
    /// clips to a scroll container's visible frame so horizontally scrolled lines stay anchored to the visible edge.
    static func clearedLineBounds(_ line: CGRect, adjacentLines: [CGRect],
                                  iconHeight: CGFloat = iconSize.height,
                                  container: CGRect? = nil) -> CGRect {
        func clipped(_ rect: CGRect) -> CGRect {
            guard let container, container.width > 0, container.height > 0, rect.intersects(container) else { return rect }
            let minX = max(rect.minX, container.minX)
            let maxX = min(rect.maxX, container.maxX)
            guard maxX > minX else { return rect }
            return CGRect(x: minX, y: rect.minY, width: maxX - minX, height: rect.height)
        }
        let base = clipped(line)
        var outMinX = base.minX
        var outMaxX = base.maxX
        let iconMinY = base.midY - iconHeight / 2 - 1
        let iconMaxY = base.midY + iconHeight / 2 + 1

        for rawAdj in adjacentLines where rawAdj.width > 0 && rawAdj.height > 0 {
            let adj = clipped(rawAdj)
            guard adj.maxY > iconMinY && adj.minY < iconMaxY else { continue }
            if adj.maxX > outMaxX, adj.maxX - base.maxX <= adjacentLineClearanceLimit {
                outMaxX = adj.maxX
            }
            if adj.minX < outMinX, base.minX - adj.minX <= adjacentLineClearanceLimit {
                outMinX = adj.minX
            }
        }
        return CGRect(x: outMinX, y: base.minY, width: max(1, outMaxX - outMinX), height: base.height)
    }

    /// Returns the best single-line rect for the release point: prefers AX `lineBounds` when valid and near
    /// `mouseUp.y`, otherwise falls back to single-line `selectionBounds`.
    static func effectiveLineRect(mouseUp: CGPoint, selectionBounds: CGRect?, lineBounds: CGRect?) -> CGRect? {
        if let line = lineBounds, line.width > 0, line.height > 0, line.height <= 80,
           abs(mouseUp.y - line.midY) <= 60 {
            return line
        }
        if let sel = selectionBounds, sel.width > 0, sel.height > 0, sel.height <= 44,
           abs(mouseUp.y - sel.midY) <= 44 {
            return sel
        }
        return nil
    }

    /// True when the gesture released at the start of the selection (right→left drag on a line, or upward multi-line drag).
    static func isAnchoredAtStart(mouseDown: CGPoint, mouseUp: CGPoint, selectionBounds: CGRect?) -> Bool {
        if let sel = selectionBounds, sel.height > 38, abs(mouseUp.y - mouseDown.y) > 12 {
            // AppKit Y grows upward: releasing higher than mouseDown means dragging backward to the start.
            return mouseUp.y > mouseDown.y
        }
        return (mouseUp.x - mouseDown.x) < -dragThreshold
    }

    /// Computes the vertical line band near `mouseUp`: uses AX line or single-line selection bounds when they agree
    /// with the cursor, otherwise estimates a line around `mouseUp.y` so multi-line drags stay where the user released.
    static func lineBand(mouseUp: CGPoint, selectionBounds: CGRect?, lineBounds: CGRect? = nil) -> (minY: CGFloat, maxY: CGFloat) {
        if let line = effectiveLineRect(mouseUp: mouseUp, selectionBounds: selectionBounds, lineBounds: lineBounds) {
            return (line.minY, line.maxY)
        }
        return (mouseUp.y - 11, mouseUp.y + 13)
    }

    /// Places the trigger icon beside the selection's line without covering any text:
    /// - Left→right (or multi-click): to the right of the line's trailing edge, vertically centered on that line.
    /// - Right→left (or upward multi-line): to the left of the line's leading edge, vertically centered on that line.
    /// - When horizontal room beside the line is insufficient (or AX line bounds are unavailable), falls back above
    ///   the line near the release edge, and below only if the line is against the top edge of the display.
    static func iconFrame(mouseDown: CGPoint, mouseUp: CGPoint, selectionBounds: CGRect?,
                          lineBounds: CGRect? = nil,
                          size: CGSize = iconSize, in visible: CGRect, margin: CGFloat = margin) -> CGRect {
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let anchorAtStart = isAnchoredAtStart(mouseDown: mouseDown, mouseUp: mouseUp, selectionBounds: selectionBounds)
        let line = effectiveLineRect(mouseUp: mouseUp, selectionBounds: selectionBounds, lineBounds: lineBounds)

        if let line {
            let centeredY = min(max(line.midY - size.height / 2, bounds.minY),
                                max(bounds.minY, bounds.maxY - size.height))
            if anchorAtStart {
                let leftX = line.minX - iconGap - size.width
                if leftX >= bounds.minX {
                    return CGRect(x: leftX.rounded(), y: centeredY.rounded(), width: size.width, height: size.height)
                }
            } else {
                let rightX = line.maxX + iconGap
                if rightX + size.width <= bounds.maxX {
                    return CGRect(x: rightX.rounded(), y: centeredY.rounded(), width: size.width, height: size.height)
                }
            }
        }

        let band = line.map { (minY: $0.minY, maxY: $0.maxY) }
            ?? lineBand(mouseUp: mouseUp, selectionBounds: selectionBounds, lineBounds: lineBounds)
        let rawX: CGFloat
        if anchorAtStart {
            rawX = (selectionBounds?.height ?? 999) <= 44 ? (selectionBounds?.minX ?? mouseUp.x) : mouseUp.x
        } else {
            let anchorRight = (selectionBounds?.height ?? 999) <= 44 ? (selectionBounds?.maxX ?? mouseUp.x) : mouseUp.x
            rawX = anchorRight - size.width
        }
        let x = min(max(rawX, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
        let aboveY = band.maxY + iconVerticalGap
        let belowY = band.minY - iconVerticalGap - size.height
        let y: CGFloat
        if aboveY + size.height <= bounds.maxY {
            y = aboveY
        } else if belowY >= bounds.minY {
            y = belowY
        } else {
            y = max(bounds.minY, min(aboveY, bounds.maxY - size.height))
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Places the compact translation-only popover near the mouseUp anchor, preferring directly below the line,
    /// flipping above if there isn't room below, and clamping strictly inside the display's visible frame.
    static func popoverFrame(mouseDown: CGPoint, mouseUp: CGPoint, selectionBounds: CGRect?,
                             lineBounds: CGRect? = nil,
                             size: CGSize, in visible: CGRect, margin: CGFloat = margin) -> CGRect {
        let band = lineBand(mouseUp: mouseUp, selectionBounds: selectionBounds, lineBounds: lineBounds)
        let bounds = visible.insetBy(dx: margin, dy: margin)
        let anchorAtStart = isAnchoredAtStart(mouseDown: mouseDown, mouseUp: mouseUp, selectionBounds: selectionBounds)
        // Align popover's leading/trailing edge naturally with the drag release side.
        let rawX: CGFloat
        if anchorAtStart {
            rawX = mouseUp.x - 16
        } else {
            rawX = mouseUp.x - size.width * 0.35
        }
        let x = min(max(rawX, bounds.minX), max(bounds.minX, bounds.maxX - size.width))

        let belowY = band.minY - popoverGap - size.height
        let aboveY = band.maxY + popoverGap
        let y: CGFloat
        if belowY >= bounds.minY {
            y = belowY
        } else if aboveY + size.height <= bounds.maxY {
            y = aboveY
        } else {
            y = max(bounds.minY, min(belowY, bounds.maxY - size.height))
        }
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }
}

/// Manages the trigger icon's auto-dismiss countdown, pausing while hovered.
@MainActor
final class SelectionAutoDismiss {
    private var task: Task<Void, Never>?
    private let delay: TimeInterval
    private let resumeDelay: TimeInterval
    private let onFire: () -> Void
    private(set) var isPaused = false

    init(delay: TimeInterval = SelectionPopupLayout.iconAutoDismissSeconds,
         resumeDelay: TimeInterval = SelectionPopupLayout.iconResumeDismissSeconds,
         onFire: @escaping () -> Void) {
        self.delay = delay
        self.resumeDelay = resumeDelay
        self.onFire = onFire
    }

    func start() {
        isPaused = false
        schedule(after: delay)
    }

    func setHovering(_ hovering: Bool) {
        if hovering {
            isPaused = true
            task?.cancel()
            task = nil
        } else if isPaused {
            isPaused = false
            schedule(after: resumeDelay)
        }
    }

    func cancel() {
        isPaused = false
        task?.cancel()
        task = nil
    }

    private func schedule(after seconds: TimeInterval) {
        task?.cancel()
        let ms = max(10, Int((seconds * 1000).rounded()))
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(ms))
            guard !Task.isCancelled, let self, !self.isPaused else { return }
            self.task = nil
            self.onFire()
        }
    }
}

// MARK: - Pure Accessibility Selection Reader (Zero Clipboard / Zero ⌘C)

/// Result of reading the current text selection purely through the macOS Accessibility API.
struct AXSelectionSnapshot {
    let text: String
    /// Selection bounds in AppKit global points (if the target app reports `AXBoundsForRange` / marker bounds).
    let bounds: CGRect?
    /// Full visual line bounds containing the release endpoint (AppKit global points), cleared past any overlapping
    /// ragged-edge adjacent line so a vertically centered icon beside this line covers zero text.
    let lineBounds: CGRect?
}

/// Reads selected text and its screen bounds strictly via Accessibility APIs. Never simulates ⌘C or touches the clipboard.
enum AXSelectionReader {
    static let log = Logger(subsystem: "com.weaveneuron.shocrot", category: "selection")

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Reads the frontmost app's current selection on a background queue so a slow target app never stalls the UI.
    static func readSelection(pid: pid_t, atAppKitPoint point: CGPoint?, mouseDown: CGPoint? = nil,
                              primaryScreenHeight: CGFloat) async -> AXSelectionSnapshot? {
        guard isTrusted, !SelectionSecurity.isSecureInputEnabled else { return nil }
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = readSelectionSync(pid: pid, atAppKitPoint: point, mouseDown: mouseDown,
                                               primaryScreenHeight: primaryScreenHeight)
                cont.resume(returning: result)
            }
        }
    }

    static func readSelectionSync(pid: pid_t, atAppKitPoint point: CGPoint?, mouseDown: CGPoint? = nil,
                                  primaryScreenHeight: CGFloat) -> AXSelectionSnapshot? {
        guard isTrusted, !SelectionSecurity.isSecureInputEnabled else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)

        var candidates: [AXUIElement] = []
        if let focused = elementAttribute(app, kAXFocusedUIElementAttribute) {
            candidates.append(focused)
        }
        if let point, primaryScreenHeight > 0 {
            let cg = SelectionPopupLayout.appKitPointToCG(point, primaryScreenHeight: primaryScreenHeight)
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(app, Float(cg.x), Float(cg.y), &hit) == .success, let hit {
                candidates.append(hit)
            }
        }

        // If any candidate sits inside a protected/password field, abort immediately without reading text.
        for candidate in candidates {
            if isProtectedElementOrAncestor(candidate) {
                log.debug("selection suppressed: protected/secure element")
                return nil
            }
        }

        for candidate in candidates {
            if let snapshot = extract(from: candidate, mouseDown: mouseDown, mouseUp: point,
                                      primaryScreenHeight: primaryScreenHeight) {
                return snapshot
            }
        }
        return nil
    }

    private static func extract(from element: AXUIElement, mouseDown: CGPoint?, mouseUp: CGPoint?,
                                primaryScreenHeight: CGFloat) -> AXSelectionSnapshot? {
        AXUIElementSetMessagingTimeout(element, 0.15)
        let rawText = selectedText(of: element)
        guard let text = SelectionPopupLayout.cleanedSelection(rawText) else { return nil }
        let bounds = selectionBounds(of: element, primaryScreenHeight: primaryScreenHeight)
        let lineBounds = selectionLineBounds(of: element, selectionBounds: bounds,
                                             mouseDown: mouseDown, mouseUp: mouseUp,
                                             primaryScreenHeight: primaryScreenHeight)
        return AXSelectionSnapshot(text: text, bounds: bounds, lineBounds: lineBounds)
    }

    /// Tries standard AXSelectedText, then AXSelectedTextRange + AXStringForRange, then WebKit marker range,
    /// then AXValue sliced by AXSelectedTextRange. Never falls back to ⌘C.
    private static func selectedText(of element: AXUIElement) -> String? {
        if let direct = stringAttribute(element, kAXSelectedTextAttribute), !direct.isEmpty {
            return direct
        }
        if let rangeValue = rawAttribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          rangeValue, &out) == .success,
               let str = out as? String, !str.isEmpty {
                return str
            }
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange), cfRange.length > 0,
               let full = stringAttribute(element, kAXValueAttribute) {
                let ns = full as NSString
                if cfRange.location >= 0, cfRange.location + cfRange.length <= ns.length {
                    let slice = ns.substring(with: NSRange(location: cfRange.location, length: cfRange.length))
                    if !slice.isEmpty { return slice }
                }
            }
        }
        if let markerRange = rawAttribute(element, "AXSelectedTextMarkerRange") {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString,
                                                          markerRange, &out) == .success,
               let str = out as? String, !str.isEmpty {
                return str
            }
        }
        return nil
    }

    private static func selectionBounds(of element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        guard primaryScreenHeight > 0 else { return nil }
        if let rangeValue = rawAttribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            if let rect = boundsForRangeValue(rangeValue, in: element, primaryScreenHeight: primaryScreenHeight) {
                return rect
            }
        }
        if let markerRange = rawAttribute(element, "AXSelectedTextMarkerRange"),
           let rect = boundsForMarkerRange(markerRange, in: element, primaryScreenHeight: primaryScreenHeight) {
            return rect
        }
        return nil
    }

    /// Reads the full visual line bounds containing the drag release endpoint via standard Cocoa AX
    /// (`AXLineForIndex` / `AXRangeForLine` / `AXBoundsForRange`) or WebKit AX (`AXLineTextMarkerRangeForTextMarker`
    /// / `AXBoundsForTextMarkerRange`), including adjacent-line clearance for wrapped paragraphs.
    private static func selectionLineBounds(of element: AXUIElement, selectionBounds: CGRect?,
                                            mouseDown: CGPoint?, mouseUp: CGPoint?,
                                            primaryScreenHeight: CGFloat) -> CGRect? {
        guard primaryScreenHeight > 0 else { return nil }
        let container = containerFrame(of: element, primaryScreenHeight: primaryScreenHeight)

        // Path A: Standard Cocoa text ranges (TextEdit, Notes, Xcode, Mail, etc.)
        if let rangeValue = rawAttribute(element, kAXSelectedTextRangeAttribute),
           CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var cfRange = CFRange(location: 0, length: 0)
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange), cfRange.length > 0 {
                let firstRect = boundsForCFRange(CFRange(location: cfRange.location, length: 1),
                                                 in: element, primaryScreenHeight: primaryScreenHeight)
                let lastIndex = cfRange.location + cfRange.length - 1
                let lastRect = cfRange.length == 1
                    ? firstRect
                    : boundsForCFRange(CFRange(location: lastIndex, length: 1),
                                       in: element, primaryScreenHeight: primaryScreenHeight)
                let useStart = prefersStartEndpoint(firstRect: firstRect, lastRect: lastRect,
                                                    selectionBounds: selectionBounds,
                                                    mouseDown: mouseDown, mouseUp: mouseUp)
                let anchorIndex = useStart ? cfRange.location : lastIndex

                if let lineNum = lineNumber(forIndex: anchorIndex, in: element),
                   let lineRect = trimmedLineRect(forLine: lineNum, in: element, primaryScreenHeight: primaryScreenHeight) {
                    var adjacent: [CGRect] = []
                    if lineNum > 0, let prev = trimmedLineRect(forLine: lineNum - 1, in: element, primaryScreenHeight: primaryScreenHeight) {
                        adjacent.append(prev)
                    }
                    if let next = trimmedLineRect(forLine: lineNum + 1, in: element, primaryScreenHeight: primaryScreenHeight) {
                        adjacent.append(next)
                    }
                    return SelectionPopupLayout.clearedLineBounds(lineRect, adjacentLines: adjacent, container: container)
                }

                // Fallback for controls that expose AXBoundsForRange without AXLineForIndex (e.g. single-line fields).
                if let sel = selectionBounds, sel.height <= 44 {
                    return SelectionPopupLayout.clearedLineBounds(sel, adjacentLines: [], container: container)
                }
                if let endpoint = useStart ? (firstRect ?? lastRect) : (lastRect ?? firstRect) {
                    return SelectionPopupLayout.clearedLineBounds(endpoint, adjacentLines: [], container: container)
                }
            }
        }

        // Path B: WebKit / Safari text markers (AXTextMarkerRange C API + AXWebConstants line queries)
        if let markerRangeRaw = rawAttribute(element, "AXSelectedTextMarkerRange"),
           CFGetTypeID(markerRangeRaw) == AXTextMarkerRangeGetTypeID() {
            let markerRange = markerRangeRaw as! AXTextMarkerRange
            let startMarker = AXTextMarkerRangeCopyStartMarker(markerRange)
            let endMarker = AXTextMarkerRangeCopyEndMarker(markerRange)
            let startLine = lineRect(forMarker: startMarker, preferLeft: false, in: element, primaryScreenHeight: primaryScreenHeight)
            let endLine = lineRect(forMarker: endMarker, preferLeft: true, in: element, primaryScreenHeight: primaryScreenHeight)
            let useStart = prefersStartEndpoint(firstRect: startLine, lastRect: endLine,
                                                selectionBounds: selectionBounds,
                                                mouseDown: mouseDown, mouseUp: mouseUp)
            let chosenMarker = useStart ? startMarker : endMarker
            if let chosenLine = useStart ? (startLine ?? endLine) : (endLine ?? startLine) {
                var adjacent: [CGRect] = []
                if let prevM = parameterizedAttribute(element, "AXPreviousLineStartTextMarkerForTextMarker", param: chosenMarker),
                   let prevRect = lineRect(forMarker: prevM, preferLeft: false, in: element, primaryScreenHeight: primaryScreenHeight),
                   abs(prevRect.midY - chosenLine.midY) > 4 {
                    adjacent.append(prevRect)
                }
                if let nextM = parameterizedAttribute(element, "AXNextLineEndTextMarkerForTextMarker", param: chosenMarker),
                   let nextRect = lineRect(forMarker: nextM, preferLeft: true, in: element, primaryScreenHeight: primaryScreenHeight),
                   abs(nextRect.midY - chosenLine.midY) > 4 {
                    adjacent.append(nextRect)
                }
                return SelectionPopupLayout.clearedLineBounds(chosenLine, adjacentLines: adjacent, container: container)
            }
        }

        return nil
    }

    private static func prefersStartEndpoint(firstRect: CGRect?, lastRect: CGRect?, selectionBounds: CGRect?,
                                             mouseDown: CGPoint?, mouseUp: CGPoint?) -> Bool {
        if let firstRect, let lastRect, abs(firstRect.midY - lastRect.midY) > 6, let mouseUp {
            let dFirst = hypot(mouseUp.x - firstRect.midX, mouseUp.y - firstRect.midY)
            let dLast = hypot(mouseUp.x - lastRect.midX, mouseUp.y - lastRect.midY)
            return dFirst < dLast
        }
        if let mouseDown, let mouseUp {
            return SelectionPopupLayout.isAnchoredAtStart(mouseDown: mouseDown, mouseUp: mouseUp,
                                                          selectionBounds: selectionBounds)
        }
        return false
    }

    private static func lineNumber(forIndex index: Int, in element: AXUIElement) -> Int? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXLineForIndexParameterizedAttribute as CFString,
                                                         NSNumber(value: index), &out) == .success,
              let num = out as? NSNumber else { return nil }
        return num.intValue
    }

    private static func trimmedLineRect(forLine lineNum: Int, in element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var rangeOut: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForLineParameterizedAttribute as CFString,
                                                         NSNumber(value: lineNum), &rangeOut) == .success,
              let rangeVal = rangeOut, CFGetTypeID(rangeVal) == AXValueGetTypeID() else { return nil }
        var lineRange = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeVal as! AXValue, .cfRange, &lineRange), lineRange.length > 0 else { return nil }

        var targetRange = lineRange
        var strOut: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                      rangeVal, &strOut) == .success,
           let str = strOut as? String {
            guard let trimmed = SelectionPopupLayout.trimmedLineRange(lineRange, text: str) else { return nil }
            targetRange = trimmed
        }
        guard let rect = boundsForCFRange(targetRange, in: element, primaryScreenHeight: primaryScreenHeight),
              rect.height <= 80 else { return nil }
        return rect
    }

    private static func boundsForCFRange(_ range: CFRange, in element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var mutable = range
        guard let axRange = AXValueCreate(.cfRange, &mutable) else { return nil }
        return boundsForRangeValue(axRange, in: element, primaryScreenHeight: primaryScreenHeight)
    }

    private static func boundsForRangeValue(_ rangeValue: CFTypeRef, in element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeValue, &out) == .success,
              let val = out, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var cgRect = CGRect.zero
        guard AXValueGetValue(val as! AXValue, .cgRect, &cgRect), cgRect.width > 0, cgRect.height > 0 else { return nil }
        return SelectionPopupLayout.cgRectToAppKit(cgRect, primaryScreenHeight: primaryScreenHeight)
    }

    private static func lineRect(forMarker marker: CFTypeRef, preferLeft: Bool,
                                 in element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        let primaryAttr = preferLeft
            ? "AXLeftLineTextMarkerRangeForTextMarker"
            : "AXRightLineTextMarkerRangeForTextMarker"
        for attr in [primaryAttr, "AXLineTextMarkerRangeForTextMarker"] {
            if let lineMR = parameterizedAttribute(element, attr, param: marker),
               let rect = boundsForMarkerRange(lineMR, in: element, primaryScreenHeight: primaryScreenHeight),
               rect.height <= 80 {
                return rect
            }
        }
        return nil
    }

    private static func boundsForMarkerRange(_ markerRange: CFTypeRef, in element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var out: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXBoundsForTextMarkerRange" as CFString,
                                                         markerRange, &out) == .success,
              let val = out, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var cgRect = CGRect.zero
        guard AXValueGetValue(val as! AXValue, .cgRect, &cgRect), cgRect.width > 0, cgRect.height > 0 else { return nil }
        return SelectionPopupLayout.cgRectToAppKit(cgRect, primaryScreenHeight: primaryScreenHeight)
    }

    /// Walks up to the nearest scroll/web viewport to bound horizontally scrolled lines.
    private static func containerFrame(of element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        var current: AXUIElement? = element
        for _ in 0..<5 {
            guard let el = current else { break }
            let role = stringAttribute(el, kAXRoleAttribute)
            if role == "AXScrollArea" || role == "AXWebArea" || role == "AXWindow" {
                if let frame = elementFrame(el, primaryScreenHeight: primaryScreenHeight) {
                    return frame
                }
            }
            current = elementAttribute(el, kAXParentAttribute)
        }
        return elementFrame(element, primaryScreenHeight: primaryScreenHeight)
    }

    private static func elementFrame(_ element: AXUIElement, primaryScreenHeight: CGFloat) -> CGRect? {
        guard let posVal = rawAttribute(element, kAXPositionAttribute), CFGetTypeID(posVal) == AXValueGetTypeID(),
              let sizeVal = rawAttribute(element, kAXSizeAttribute), CFGetTypeID(sizeVal) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posVal as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeVal as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return nil }
        return SelectionPopupLayout.cgRectToAppKit(CGRect(origin: origin, size: size), primaryScreenHeight: primaryScreenHeight)
    }

    private static func parameterizedAttribute(_ element: AXUIElement, _ name: String, param: CFTypeRef) -> CFTypeRef? {
        var out: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, param, &out) == .success ? out : nil
    }

    private static func isProtectedElementOrAncestor(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<4 {
            guard let el = current else { break }
            let role = stringAttribute(el, kAXRoleAttribute)
            let subrole = stringAttribute(el, kAXSubroleAttribute)
            let desc = stringAttribute(el, kAXRoleDescriptionAttribute)
            if SelectionSecurity.isProtected(role: role, subrole: subrole, roleDescription: desc,
                                             isSecureInputEnabled: SelectionSecurity.isSecureInputEnabled) {
                return true
            }
            current = elementAttribute(el, kAXParentAttribute)
        }
        return false
    }

    private static func rawAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        rawAttribute(element, name) as? String
    }

    private static func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = rawAttribute(element, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
}

// MARK: - Compact Translation-Only Model

@MainActor
final class SelectionTranslateModel: ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let name: String
        let symbol: String
        var text = ""
        var error: Error?
        var isLoading = true
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var resolvedSource: Language?
    @Published private(set) var resolvedTarget: Language?
    @Published private(set) var hasServices = true
    private(set) var sourceText = ""

    private var tasks: [Task<Void, Never>] = []
    private let services: () -> [TranslationService]

    init(services: @escaping () -> [TranslationService] = { TranslationServices.enabled }) {
        self.services = services
    }

    func translate(_ text: String) {
        cancel()
        sourceText = text
        let enabled = services()
        hasServices = !enabled.isEmpty
        let detected = Language.detect(text)
        let from = detected ?? Language.named("en")
        let to = Language.target(for: from)
        resolvedSource = from
        resolvedTarget = to
        entries = enabled.enumerated().map { Entry(id: $0, name: $1.name, symbol: $1.symbol) }
        tasks = enabled.enumerated().map { index, service in
            Task { [weak self] in
                do {
                    for try await partial in service.translate(text, from: from, to: to) {
                        guard !Task.isCancelled else { return }
                        self?.update(index) { $0.text = partial }
                    }
                    guard !Task.isCancelled else { return }
                    self?.update(index) { $0.isLoading = false }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.update(index) { $0.error = error; $0.isLoading = false }
                }
            }
        }
    }

    var primaryTranslation: String? {
        entries.first { $0.error == nil && !$0.isLoading && !$0.text.isEmpty }?.text
    }

    func cancel() {
        tasks.forEach { $0.cancel() }
        tasks = []
    }

    private func update(_ index: Int, _ mutate: (inout Entry) -> Void) {
        guard entries.indices.contains(index) else { return }
        mutate(&entries[index])
    }
}

// MARK: - Event-Driven Selection Controller

/// Listens passively for mouse-up text selections across apps (zero polling), shows a non-activating
/// Liquid Glass translate icon at the mouse-up point, and opens a compact translation-only popover on click.
@MainActor
final class SelectionTranslateController {
    static let shared = SelectionTranslateController()

    private struct PendingContext {
        let text: String
        let mouseDown: CGPoint
        let mouseUp: CGPoint
        let selectionBounds: CGRect?
        let lineBounds: CGRect?
        let screen: NSScreen
    }

    private var mouseMonitor: Any?
    private var dismissMonitors: [Any] = []
    private var appObserver: NSObjectProtocol?

    private var mouseDownPoint: CGPoint?
    private var mouseDownAppPID: pid_t?
    private var pendingReadTask: Task<Void, Never>?
    private var currentContext: PendingContext?

    private var iconPanel: NonActivatingPanel?
    private var popoverPanel: NonActivatingPanel?
    private var autoDismiss: SelectionAutoDismiss?
    private let popoverModel = SelectionTranslateModel()

    func start() {
        installMouseMonitor()
    }

    func dismissAll() {
        pendingReadTask?.cancel()
        pendingReadTask = nil
        autoDismiss?.cancel()
        autoDismiss = nil
        popoverModel.cancel()
        Speaker.shared.stop()
        iconPanel?.orderOut(nil)
        iconPanel = nil
        popoverPanel?.orderOut(nil)
        popoverPanel = nil
        currentContext = nil
        removeDismissMonitors()
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
            let location = NSEvent.mouseLocation
            let type = event.type
            let clicks = event.clickCount
            Task { @MainActor in
                self?.handleGlobalMouse(type: type, location: location, clickCount: clicks)
            }
        }
    }

    private func handleGlobalMouse(type: NSEvent.EventType, location: CGPoint, clickCount: Int) {
        if type == .leftMouseDown {
            // Clicking outside our floating panels dismisses them immediately.
            if !pointInsideOwnPanels(location) {
                dismissAll()
            }
            mouseDownPoint = location
            mouseDownAppPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return
        }

        // leftMouseUp
        guard let down = mouseDownPoint else { return }
        mouseDownPoint = nil

        guard !CaptureSession.isActive, !ScrollCapture.isActive, !ScreenRecording.isActive else { return }
        guard !pointInsideOwnPanels(location) else { return }
        guard AXSelectionReader.isTrusted, !SelectionSecurity.isSecureInputEnabled else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        // Ignore drags that switched apps mid-gesture (e.g. window drag or cross-app drop).
        if let downPID = mouseDownAppPID, downPID != frontApp.processIdentifier { return }
        guard SelectionPopupLayout.shouldTrigger(mouseDown: down, mouseUp: location, clickCount: clickCount) else { return }

        let targetPID = frontApp.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        guard let screen = WindowPlacement.screen(for: CGRect(origin: location, size: .zero)) ?? WindowPlacement.mouseScreen else { return }

        pendingReadTask?.cancel()
        pendingReadTask = Task { @MainActor [weak self] in
            // Let the frontmost app finish updating its selection (and let a double-click's 2nd click supersede the 1st).
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
            guard let snapshot = await AXSelectionReader.readSelection(pid: targetPID, atAppKitPoint: location,
                                                                       mouseDown: down,
                                                                       primaryScreenHeight: primaryHeight) else { return }
            guard !Task.isCancelled else { return }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return }
            self.showIcon(for: PendingContext(text: snapshot.text, mouseDown: down, mouseUp: location,
                                              selectionBounds: snapshot.bounds, lineBounds: snapshot.lineBounds,
                                              screen: screen))
        }
    }

    private func pointInsideOwnPanels(_ point: CGPoint) -> Bool {
        if let iconPanel, iconPanel.isVisible, iconPanel.frame.contains(point) { return true }
        if let popoverPanel, popoverPanel.isVisible, popoverPanel.frame.contains(point) { return true }
        return false
    }

    // MARK: - Trigger Icon

    private func showIcon(for context: PendingContext) {
        dismissAll()
        currentContext = context

        let dismiss = SelectionAutoDismiss { [weak self] in self?.dismissAll() }
        autoDismiss = dismiss

        let inset = SelectionPopupLayout.iconCanvasInset
        let iconRect = SelectionPopupLayout.iconFrame(mouseDown: context.mouseDown, mouseUp: context.mouseUp,
                                                      selectionBounds: context.selectionBounds,
                                                      lineBounds: context.lineBounds,
                                                      in: context.screen.visibleFrame)
        let dir = SelectionPopupLayout.isAnchoredAtStart(mouseDown: context.mouseDown, mouseUp: context.mouseUp,
                                                         selectionBounds: context.selectionBounds) ? "rl" : "lr"
        AXSelectionReader.log.notice("selection.icon dir=\(dir, privacy: .public) icon=\(NSStringFromRect(iconRect), privacy: .public) line=\(context.lineBounds.map(NSStringFromRect) ?? "nil", privacy: .public) sel=\(context.selectionBounds.map(NSStringFromRect) ?? "nil", privacy: .public)")
        let panelFrame = iconRect.insetBy(dx: -inset, dy: -inset)

        let host = NSHostingView(rootView: SelectionTriggerView(
            onHover: { [weak self] hovering in self?.autoDismiss?.setHovering(hovering) },
            onTap: { [weak self] in self?.openPopover() }
        ))
        let panel = NonActivatingPanel(contentRect: panelFrame)
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        iconPanel = panel
        dismiss.start()
        installDismissMonitors()
    }

    // MARK: - Translation-Only Popover

    private func openPopover() {
        guard let context = currentContext else { return }
        autoDismiss?.cancel()
        autoDismiss = nil
        iconPanel?.orderOut(nil)
        iconPanel = nil

        popoverModel.translate(context.text)

        let view = SelectionPopoverView(
            model: popoverModel,
            onExpand: { [weak self] in
                guard let self, let ctx = self.currentContext else { return }
                let anchor = ctx.selectionBounds ?? CGRect(origin: ctx.mouseUp, size: .zero)
                let text = ctx.text
                self.dismissAll()
                TranslatePanel.show(text: text, near: anchor)
            },
            onOpenSettings: { [weak self] in
                self?.dismissAll()
                SettingsWindow.show(tab: .translate)
            },
            onClose: { [weak self] in self?.dismissAll() },
            onHeightChange: { [weak self] height in self?.repositionPopover(height: height) }
        )

        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        let initialSize = CGSize(width: SelectionPopupLayout.popoverWidth, height: 84)
        let frame = SelectionPopupLayout.popoverFrame(mouseDown: context.mouseDown, mouseUp: context.mouseUp,
                                                      selectionBounds: context.selectionBounds,
                                                      lineBounds: context.lineBounds,
                                                      size: initialSize, in: context.screen.visibleFrame)
        let panel = NonActivatingPanel(contentRect: frame)
        panel.hasShadow = true
        panel.contentViewController = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        popoverPanel = panel
        installDismissMonitors()
    }

    private func repositionPopover(height: CGFloat) {
        guard let panel = popoverPanel, let context = currentContext, height > 0 else { return }
        let clampedHeight = min(height, WindowPlacement.maxHeight(in: context.screen.visibleFrame))
        let target = SelectionPopupLayout.popoverFrame(mouseDown: context.mouseDown, mouseUp: context.mouseUp,
                                                       selectionBounds: context.selectionBounds,
                                                       lineBounds: context.lineBounds,
                                                       size: CGSize(width: SelectionPopupLayout.popoverWidth, height: clampedHeight),
                                                       in: context.screen.visibleFrame)
        guard abs(panel.frame.height - target.height) > 1 || abs(panel.frame.minY - target.minY) > 1 else { return }
        panel.setFrame(target, display: true)
    }

    // MARK: - Dismiss Monitors (Active Only While Icon or Popover Is Visible)

    private func installDismissMonitors() {
        guard dismissMonitors.isEmpty else { return }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .scrollWheel, .keyDown], handler: { [weak self] event in
            let type = event.type
            let keyCode = event.keyCode
            let loc = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self else { return }
                if type == .scrollWheel && self.pointInsideOwnPanels(loc) { return }
                if type == .keyDown && keyCode == 53 { self.dismissAll(); return }
                // Any typing in the target app invalidates the selection.
                if type == .keyDown { self.dismissAll(); return }
                if type == .rightMouseDown && !self.pointInsideOwnPanels(loc) { self.dismissAll(); return }
                if type == .scrollWheel && self.iconPanel != nil { self.dismissAll() }
            }
        }) { dismissMonitors.append(m) }

        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown, event.keyCode == 53 {
                self.dismissAll()
                return nil
            }
            if event.type != .keyDown, event.window !== self.iconPanel, event.window !== self.popoverPanel {
                self.dismissAll()
            }
            return event
        }) { dismissMonitors.append(m) }

        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissAll() }
        }
    }

    private func removeDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
            self.appObserver = nil
        }
    }
}

/// Non-activating borderless floating panel that never steals key focus or alters the frontmost app's selection.
private final class NonActivatingPanel: NSPanel {
    init(contentRect: CGRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI Views (Liquid Glass)

private struct SelectionTriggerView: View {
    let onHover: (Bool) -> Void
    let onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            Image(systemName: "translate")
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(hovering ? Color.accentColor : Color.primary)
                .frame(width: SelectionPopupLayout.iconSize.width, height: SelectionPopupLayout.iconSize.height)
                .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(hovering ? 0.85 : 0.72)), in: .circle)
                .overlay(Circle().strokeBorder(.primary.opacity(hovering ? 0.22 : 0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                .scaleEffect(hovering ? 1.06 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(SelectionPopupLayout.iconCanvasInset)
        .onHover { h in
            hovering = h
            onHover(h)
        }
        .animation(.snappy(duration: 0.15), value: hovering)
        .help(L("selection.iconHelp"))
        .accessibilityLabel(L("selection.iconHelp"))
        .environment(\.controlActiveState, .key)
    }
}

private struct SelectionPopoverView: View {
    @ObservedObject var model: SelectionTranslateModel
    let onExpand: () -> Void
    let onOpenSettings: () -> Void
    let onClose: () -> Void
    let onHeightChange: (CGFloat) -> Void

    @ObservedObject private var speaker = Speaker.shared
    @State private var copied = false
    @State private var downloadRequest: TranslationSession.Configuration?

    private var showsServiceHeaders: Bool { model.entries.count > 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasServices {
                HStack {
                    Text(L("translate.noServices")).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button(L("translate.openSettings"), action: onOpenSettings)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.entries) { entry in
                            if showsServiceHeaders {
                                HStack(spacing: 4) {
                                    Image(systemName: entry.symbol).font(.system(size: 10.5))
                                    Text(entry.name).font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.secondary)
                            }
                            entryContent(entry)
                            if showsServiceHeaders && entry.id != model.entries.last?.id {
                                Divider().opacity(0.45)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: SelectionPopupLayout.popoverMaxHeight - 48)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 2) {
                if let target = model.resolvedTarget {
                    Text(target.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if let text = model.primaryTranslation {
                    PopoverIconButton(symbol: speaker.speakingID == "sel" ? "stop.fill" : "speaker.wave.2",
                                      help: speakHelp(speaking: speaker.speakingID == "sel")) {
                        speaker.toggle(text, language: model.resolvedTarget, id: "sel")
                    }
                    PopoverIconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: L("translate.copyTranslation")) {
                        ImageOutput.copyText(text)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                    }
                }
                PopoverIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: L("selection.expand"), action: onExpand)
                PopoverIconButton(symbol: "xmark", help: L("common.closeEsc"), action: onClose)
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: SelectionPopupLayout.popoverWidth)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.76)),
                     in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .translationTask(downloadRequest) { session in
            try? await session.prepareTranslation()
            AppleTranslationService.invalidateCache()
            model.translate(model.sourceText)
        }
        .environment(\.controlActiveState, .key)
    }

    @ViewBuilder
    private func entryContent(_ entry: SelectionTranslateModel.Entry) -> some View {
        if let error = entry.error {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                switch (error as? TranslationFailure)?.recovery {
                case .downloadLanguages:
                    Button(L("translate.download")) { requestDownload() }.controlSize(.small)
                case .openSettings:
                    Button(L("translate.settingsButton"), action: onOpenSettings).controlSize(.small)
                case nil:
                    EmptyView()
                }
            }
        } else if !entry.text.isEmpty {
            Text(entry.text)
                .font(.system(size: 13.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(.primary.opacity(0.08))
                    .frame(width: 240, height: 11)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous).fill(.primary.opacity(0.06))
                    .frame(width: 170, height: 11)
            }
            .padding(.vertical, 2)
            .accessibilityHidden(true)
        }
    }

    private func requestDownload() {
        guard let source = model.resolvedSource, let target = model.resolvedTarget else { return }
        if downloadRequest?.source == source.locale && downloadRequest?.target == target.locale {
            downloadRequest?.invalidate()
        } else {
            downloadRequest = TranslationSession.Configuration(source: source.locale, target: target.locale)
        }
    }
}

private struct PopoverIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.09) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onDisappear { hovering = false }
        .help(help)
        .accessibilityLabel(help)
    }
}
