import AppKit
import ApplicationServices

/// Snapping to UI elements inside a window (a sidebar, a list, a button), through the Accessibility API.
/// Only works once Shocrot is trusted; queries run off the main thread so a slow app can't stall the overlay.
final class ElementProbe: @unchecked Sendable {
    static let shared = ElementProbe()

    private let queue = DispatchQueue(label: "shocrot.elements", qos: .userInteractive)
    // Main thread only.
    private var busy = false
    private var pending: (point: CGPoint, pid: pid_t, completion: ([CGRect]) -> Void)?

    static var isAvailable: Bool { AXIsProcessTrusted() }

    /// Frames of the elements under `point` (global, top-left origin), innermost first. While a query is running
    /// only the latest request waits; its completion runs on the main thread, stale ones are dropped.
    func frames(at point: CGPoint, pid: pid_t, completion: @escaping ([CGRect]) -> Void) {
        if busy { pending = (point, pid, completion); return }
        busy = true
        queue.async {
            let frames = Self.elementFrames(at: point, pid: pid)
            DispatchQueue.main.async {
                self.busy = false
                if let next = self.pending {
                    self.pending = nil
                    self.frames(at: next.point, pid: next.pid, completion: next.completion)
                } else {
                    completion(frames)
                }
            }
        }
    }

    private static func elementFrames(at point: CGPoint, pid: pid_t) -> [CGRect] {
        // Hit-test inside that app only: the overlay covering the screen belongs to us, not to it.
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return [] }
        var frames: [CGRect] = []
        for _ in 0..<16 {
            if let f = frame(of: element) { frames.append(f) }
            if string(element, kAXRoleAttribute) == kAXWindowRole as String { break }
            guard let parent = value(element, kAXParentAttribute), CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { break }
            element = parent as! AXUIElement
        }
        return frames
    }

    private static func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }

    private static func string(_ e: AXUIElement, _ attribute: String) -> String? {
        value(e, attribute) as? String
    }

    private static func frame(of e: AXUIElement) -> CGRect? {
        guard let v = value(e, "AXFrame"), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        return AXValueGetValue(v as! AXValue, .cgRect, &r) ? r : nil
    }

    /// Turns element frames (innermost first, already in view coordinates) into snap levels within `window`:
    /// clipped to it, tiny ones, near-duplicates and odd parents that don't enclose their child dropped,
    /// ending with the window itself.
    static func levels(_ frames: [CGRect], window: CGRect) -> [CGRect] {
        var out: [CGRect] = []
        for f in frames {
            let r = f.intersection(window).integral
            guard !r.isNull, r.width >= 8, r.height >= 8 else { continue }
            if r.width >= window.width - 4, r.height >= window.height - 4 { continue } // the window itself
            if let last = out.last {
                if !r.insetBy(dx: -3, dy: -3).contains(last) { continue }
                if r.insetBy(dx: 3, dy: 3).width <= last.width, r.insetBy(dx: 3, dy: 3).height <= last.height { continue }
            }
            out.append(r)
        }
        out.append(window)
        return out
    }
}
