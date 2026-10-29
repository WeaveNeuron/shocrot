import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum Tool: String, CaseIterable, Identifiable {
    case rect, ellipse, arrow, pen, highlighter, mosaic, text, counter

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "scribble"
        case .highlighter: return "highlighter"
        case .mosaic: return "checkerboard.rectangle"
        case .text: return "character.textbox"
        case .counter: return "1.circle"
        }
    }

    var title: String {
        switch self {
        case .rect: return "矩形 (R)"
        case .ellipse: return "椭圆 (O)"
        case .arrow: return "箭头 (A)"
        case .pen: return "画笔 (P)"
        case .highlighter: return "荧光笔 (H)"
        case .mosaic: return "马赛克 (M)"
        case .text: return "文字 (T)"
        case .counter: return "序号 (N)"
        }
    }

    var shortcut: Character {
        switch self {
        case .rect: return "r"
        case .ellipse: return "o"
        case .arrow: return "a"
        case .pen: return "p"
        case .highlighter: return "h"
        case .mosaic: return "m"
        case .text: return "t"
        case .counter: return "n"
        }
    }

    var usesColor: Bool { self != .mosaic }
}

struct Annotation {
    var tool: Tool
    /// Two points (start, end) for shapes, a polyline for pens, one point for text/counter.
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var number: Int = 0

    var boundingRect: CGRect {
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
    }

    static func font(for width: CGFloat) -> NSFont {
        .systemFont(ofSize: 10 + width * 3, weight: .semibold)
    }

    static func textAttributes(color: NSColor, width: CGFloat) -> [NSAttributedString.Key: Any] {
        let shadow = NSShadow()
        shadow.shadowColor = (color.isLight ? NSColor.black : NSColor.white).withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = .zero
        return [.font: font(for: width), .foregroundColor: color, .shadow: shadow]
    }
}

/// Draws annotations into a CGContext whose user space matches the overlay view (points, bottom-left origin).
struct AnnotationRenderer {
    /// Lazily produced pixelated copy of the backdrop, drawn through mosaic rectangles.
    let mosaicImage: () -> CGImage?
    let backdropRect: CGRect

    func draw(_ a: Annotation, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)

        switch a.tool {
        case .rect:
            guard a.points.count >= 2 else { return }
            let r = rect(a.points[0], a.points[1])
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(4, r.width / 2), cornerHeight: min(4, r.height / 2), transform: nil))
            ctx.strokePath()
        case .ellipse:
            guard a.points.count >= 2 else { return }
            ctx.strokeEllipse(in: rect(a.points[0], a.points[1]))
        case .arrow:
            guard a.points.count >= 2 else { return }
            drawArrow(from: a.points[0], to: a.points[1], width: a.width, in: ctx)
        case .pen, .highlighter:
            guard let first = a.points.first else { return }
            if a.tool == .highlighter {
                ctx.setBlendMode(.multiply)
                ctx.setStrokeColor(a.color.withAlphaComponent(0.45).cgColor)
                ctx.setLineWidth(a.width * 5)
                ctx.setLineCap(.butt)
            }
            ctx.addPath(smoothPath(first: first, rest: a.points.dropFirst()))
            ctx.strokePath()
        case .mosaic:
            guard a.points.count >= 2, let img = mosaicImage() else { return }
            ctx.clip(to: rect(a.points[0], a.points[1]))
            ctx.interpolationQuality = .none
            ctx.draw(img, in: backdropRect)
        case .text:
            guard let p = a.points.first, !a.text.isEmpty else { return }
            let str = NSAttributedString(string: a.text, attributes: Annotation.textAttributes(color: a.color, width: a.width))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let size = str.boundingRect(with: CGSize(width: 10000, height: 10000), options: [.usesLineFragmentOrigin]).size
            str.draw(with: CGRect(x: p.x, y: p.y - size.height, width: size.width + 4, height: size.height),
                     options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        case .counter:
            guard let p = a.points.first else { return }
            let d = 14 + a.width * 4
            let circle = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            ctx.setShadow(offset: CGSize(width: 0, height: -1), blur: 3, color: NSColor.black.withAlphaComponent(0.3).cgColor)
            ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0, color: nil)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(max(1.5, d / 14))
            ctx.strokeEllipse(in: circle.insetBy(dx: 0.75, dy: 0.75))
            let str = NSAttributedString(string: "\(a.number)", attributes: [
                .font: NSFont.systemFont(ofSize: d * 0.55, weight: .bold),
                .foregroundColor: a.color.isLight ? NSColor.black : NSColor.white,
            ])
            let s = str.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            str.draw(at: CGPoint(x: p.x - s.width / 2, y: p.y - s.height / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func smoothPath(first: CGPoint, rest: ArraySlice<CGPoint>) -> CGPath {
        let path = CGMutablePath()
        path.move(to: first)
        var prev = first
        for p in rest {
            let mid = CGPoint(x: (prev.x + p.x) / 2, y: (prev.y + p.y) / 2)
            path.addQuadCurve(to: mid, control: prev)
            prev = p
        }
        path.addLine(to: prev)
        return path
    }

    private func drawArrow(from s: CGPoint, to e: CGPoint, width: CGFloat, in ctx: CGContext) {
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let ux = dx / len, uy = dy / len
        let headLen = min(len * 0.6, 10 + width * 4)
        let headHalf = headLen * 0.55
        let base = CGPoint(x: e.x - ux * headLen, y: e.y - uy * headLen)
        // Tapered shaft: thin at the tail, full width near the head.
        let tailHalf = max(0.75, width * 0.25), shaftHalf = width * 0.6
        let nx = -uy, ny = ux
        let path = CGMutablePath()
        path.move(to: CGPoint(x: s.x + nx * tailHalf, y: s.y + ny * tailHalf))
        path.addLine(to: CGPoint(x: base.x + nx * shaftHalf, y: base.y + ny * shaftHalf))
        path.addLine(to: CGPoint(x: base.x + nx * headHalf, y: base.y + ny * headHalf))
        path.addLine(to: e)
        path.addLine(to: CGPoint(x: base.x - nx * headHalf, y: base.y - ny * headHalf))
        path.addLine(to: CGPoint(x: base.x - nx * shaftHalf, y: base.y - ny * shaftHalf))
        path.addLine(to: CGPoint(x: s.x - nx * tailHalf, y: s.y - ny * tailHalf))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.fillPath()
    }
}

extension NSFont {
    /// SF Pro Rounded with tabular digits, used for measurements and labels.
    static func roundedMonospaced(size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
}

extension NSColor {
    var isLight: Bool {
        guard let c = usingColorSpace(.sRGB) else { return false }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent > 0.7
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)),
                      Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

extension CGImage {
    /// A pixelated copy of the image used for mosaic redaction.
    func pixelated(blockSize: CGFloat) -> CGImage? {
        let ci = CIImage(cgImage: self)
        let filter = CIFilter.pixellate()
        filter.inputImage = ci.clampedToExtent()
        filter.scale = Float(blockSize)
        filter.center = .zero
        guard let out = filter.outputImage?.cropped(to: ci.extent) else { return nil }
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(out, from: ci.extent)
    }
}
