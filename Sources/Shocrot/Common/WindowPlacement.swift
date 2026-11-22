import AppKit

/// Puts our floating windows on the right display and keeps them inside its visible area (menu bar and Dock
/// excluded). Everything is in AppKit global coordinates: origin at the bottom left of the primary display, y up.
enum WindowPlacement {
    static let margin: CGFloat = 8

    /// The display showing most of `rect`; for a point-sized rect (or one between displays), the one whose frame
    /// holds its origin, edges included.
    static func screen(for rect: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        return index(for: rect, among: screens.map(\.frame)).map { screens[$0] }
    }

    /// The display under the pointer, else the main one.
    static var mouseScreen: NSScreen? {
        screen(for: CGRect(origin: NSEvent.mouseLocation, size: .zero)) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static func index(for rect: CGRect, among frames: [CGRect]) -> Int? {
        let areas = frames.map { frame -> CGFloat in
            let overlap = frame.intersection(rect)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 { return best }
        let p = rect.origin
        return frames.firstIndex { p.x >= $0.minX && p.x <= $0.maxX && p.y >= $0.minY && p.y <= $0.maxY }
    }

    /// Moves `frame` inside `bounds` inset by `margin`, keeping its size. When it doesn't fit, the top left wins,
    /// so a title bar or header always stays reachable.
    static func fit(_ frame: CGRect, in bounds: CGRect, margin: CGFloat = margin) -> CGRect {
        let b = bounds.insetBy(dx: margin, dy: margin)
        var f = frame
        if f.maxX > b.maxX { f.origin.x = b.maxX - f.width }
        if f.minX < b.minX { f.origin.x = b.minX }
        if f.minY < b.minY { f.origin.y = b.minY }
        if f.maxY > b.maxY { f.origin.y = b.maxY - f.height }
        return f
    }

    /// Where `frame` has to go to be fully visible: inside the visible frame of the display showing most of it
    /// (`fallback` when it is on none), inset by `margin`. With `canShrink` a frame larger than that area is cut
    /// down to it, keeping its top left; otherwise, as in `fit`, the top left wins.
    static func onScreen(_ frame: CGRect, screens: [(frame: CGRect, visible: CGRect)], fallback: CGRect?,
                         canShrink: Bool = false, margin: CGFloat = margin) -> CGRect {
        guard let visible = index(for: frame, among: screens.map(\.frame)).map({ screens[$0].visible }) ?? fallback
        else { return frame }
        var f = frame
        if canShrink {
            let b = visible.insetBy(dx: margin, dy: margin)
            let top = f.maxY
            f.size = CGSize(width: min(f.width, b.width), height: min(f.height, b.height))
            f.origin.y = top - f.height
        }
        return fit(f, in: visible, margin: margin)
    }

    /// The tallest a window may be to fit inside `visible` with the usual margin.
    static func maxHeight(in visible: CGRect, margin: CGFloat = margin) -> CGFloat {
        max(0, visible.height - 2 * margin)
    }

    /// Top-left corner for a window of `size` next to `anchor` (a selection, or a point as a zero-size rect),
    /// tried in order: below it, above it, right of it, left of it. When none fits (a large or full-screen
    /// selection), it goes centred in the upper part of `bounds`. The result always lies inside `bounds`.
    static func topLeft(for size: CGSize, beside anchor: CGRect, in bounds: CGRect, gap: CGFloat = 12,
                        margin: CGFloat = margin) -> CGPoint {
        let b = bounds.insetBy(dx: margin, dy: margin)
        let w = size.width, h = size.height
        func x(_ value: CGFloat) -> CGFloat { max(b.minX, min(value, b.maxX - w)) }
        func top(_ value: CGFloat) -> CGFloat { min(b.maxY, max(value, b.minY + h)) }

        if anchor.minY - gap - h >= b.minY {
            return CGPoint(x: x(anchor.minX), y: top(anchor.minY - gap))
        }
        if anchor.maxY + gap + h <= b.maxY {
            return CGPoint(x: x(anchor.minX), y: top(anchor.maxY + gap + h))
        }
        if anchor.maxX + gap + w <= b.maxX {
            return CGPoint(x: anchor.maxX + gap, y: top(anchor.maxY))
        }
        if anchor.minX - gap - w >= b.minX {
            return CGPoint(x: anchor.minX - gap - w, y: top(anchor.maxY))
        }
        return centeredTopLeft(for: size, in: bounds, margin: margin)
    }

    /// Horizontally centred, in the upper part of `bounds`: where a panel opened without an anchor goes.
    static func centeredTopLeft(for size: CGSize, in bounds: CGRect, margin: CGFloat = margin) -> CGPoint {
        let b = bounds.insetBy(dx: margin, dy: margin)
        let x = max(b.minX, min(b.midX - size.width / 2, b.maxX - size.width))
        let top = min(b.maxY, max(bounds.maxY - bounds.height * 0.18, b.minY + size.height))
        return CGPoint(x: x, y: top)
    }
}
