import CoreGraphics

/// Snapshot-based annotation history, so moves and deletions are undoable too.
struct AnnotationHistory {
    private(set) var undoStack: [[Annotation]] = []
    private(set) var redoStack: [[Annotation]] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func record(_ current: [Annotation]) {
        undoStack.append(current)
        redoStack.removeAll()
    }

    mutating func undo(from current: [Annotation]) -> [Annotation]? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(from current: [Annotation]) -> [Annotation]? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    /// Moving the selection carries its annotations along, including the ones in history.
    mutating func shift(by d: CGPoint) {
        undoStack = undoStack.map { $0.map { $0.shifted(by: d) } }
        redoStack = redoStack.map { $0.map { $0.shifted(by: d) } }
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}

extension Annotation {
    func shifted(by d: CGPoint) -> Annotation {
        var a = self
        a.points = points.map { CGPoint(x: $0.x + d.x, y: $0.y + d.y) }
        return a
    }
}

enum SelectionHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
}

enum SelectionGeometry {
    /// `r` moved back inside `bounds`, keeping its size.
    static func clamped(_ r: CGRect, in bounds: CGRect) -> CGRect {
        var r = r
        r.origin.x = min(max(r.minX, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.minY, bounds.minY), bounds.maxY - r.height)
        return r
    }

    /// `original` with `handle` dragged to `p`; nil when the result would be too small to keep.
    static func resized(_ original: CGRect, handle: SelectionHandle, to p: CGPoint, in bounds: CGRect) -> CGRect? {
        var minX = original.minX, maxX = original.maxX, minY = original.minY, maxY = original.maxY
        switch handle {
        case .topLeft: minX = p.x; maxY = p.y
        case .top: maxY = p.y
        case .topRight: maxX = p.x; maxY = p.y
        case .right: maxX = p.x
        case .bottomRight: maxX = p.x; minY = p.y
        case .bottom: minY = p.y
        case .bottomLeft: minX = p.x; minY = p.y
        case .left: minX = p.x
        }
        let r = CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
            .intersection(bounds).integral
        return r.width >= 2 && r.height >= 2 ? r : nil
    }
}

extension CGImage {
    /// A copy with its own pixels. A cropped CGImage keeps the whole source image alive,
    /// so a small pin would otherwise hold on to a full-screen snapshot.
    func detachedCopy() -> CGImage {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return self }
        ctx.interpolationQuality = .none
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage() ?? self
    }
}
