// Renders the Shocrot app icon (1024×1024 PNG). Usage: swift make_icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// macOS icon grid: 824pt squircle centered with drop shadow.
let inset: CGFloat = 100
let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = 185
let shape = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(gray: 0, alpha: 0.35))
ctx.addPath(shape)
ctx.setFillColor(CGColor(gray: 0, alpha: 1))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
let gradient = CGGradient(colorsSpace: space, colors: [
    CGColor(srgbRed: 0.36, green: 0.42, blue: 1.00, alpha: 1),
    CGColor(srgbRed: 0.12, green: 0.16, blue: 0.55, alpha: 1),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
// Soft top highlight
let gloss = CGGradient(colorsSpace: space, colors: [
    CGColor(gray: 1, alpha: 0.18), CGColor(gray: 1, alpha: 0),
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.midY), options: [])
ctx.restoreGState()

// Viewfinder corners
ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let f = body.insetBy(dx: 150, dy: 150)
let arm: CGFloat = 120
for (corner, dx, dy) in [(CGPoint(x: f.minX, y: f.maxY), 1.0, -1.0), (CGPoint(x: f.maxX, y: f.maxY), -1.0, -1.0),
                         (CGPoint(x: f.minX, y: f.minY), 1.0, 1.0), (CGPoint(x: f.maxX, y: f.minY), -1.0, 1.0)] {
    ctx.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
    ctx.addLine(to: corner)
    ctx.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
}
ctx.strokePath()

// Text lines inside the viewfinder
let lines: [(CGFloat, CGFloat)] = [(0.66, 1.0), (0.50, 0.78), (0.34, 0.9)]
ctx.setLineWidth(40)
for (i, (y, w)) in lines.enumerated() {
    let inner = f.insetBy(dx: 95, dy: 0)
    let yy = f.minY + f.height * y
    ctx.setStrokeColor(i == 1 ? CGColor(srgbRed: 1, green: 0.82, blue: 0.25, alpha: 1) : CGColor(gray: 1, alpha: 0.92))
    ctx.move(to: CGPoint(x: inner.minX, y: yy))
    ctx.addLine(to: CGPoint(x: inner.minX + inner.width * w, y: yy))
    ctx.strokePath()
}

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
