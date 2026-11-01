import CoreGraphics
import Testing
@testable import Shocrot

/// A long "page": text-like bars of varying length and shade on white, deterministic per seed.
private func makePage(width: Int, height: Int, seed: UInt64 = 7) -> CGContext {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var state = seed
    func next() -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int(state >> 33) }
    var y = 0
    while y < height {
        let lineHeight = 10 + next() % 8
        var x = 6
        while x < width - 20 {
            let w = 8 + next() % 40
            ctx.setFillColor(CGColor(gray: CGFloat(next() % 60) / 100, alpha: 1))
            // Context y is bottom-up; page row `y` is from the top.
            ctx.fill(CGRect(x: x, y: height - y - lineHeight + 2, width: min(w, width - x - 6), height: lineHeight - 4))
            x += w + 4 + next() % 10
        }
        y += lineHeight + next() % 12
    }
    return ctx
}

/// What the screen shows at a scroll offset: an optional fixed bar on top and at the bottom, page content between.
private func frame(of page: CGImage, offset: Int, height: Int, header: Int, footer: Int, caret: Bool = false) -> CGImage {
    let w = page.width
    let ctx = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    let content = page.copyRows(offset ..< offset + height - header - footer)!
    ctx.draw(content, in: CGRect(x: 0, y: footer, width: w, height: content.height))
    if header > 0 {
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - header, width: w, height: header))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 10, y: height - header + 6, width: 60, height: header - 12))
    }
    if footer > 0 {
        ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: footer))
        ctx.setFillColor(CGColor(gray: 0.3, alpha: 1))
        ctx.fill(CGRect(x: w - 80, y: 5, width: 70, height: footer - 10))
    }
    if caret { // a text cursor in the middle of the view
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: w / 2, y: height / 2, width: 2, height: 16))
    }
    return ctx.makeImage()!
}

private func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    data.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }
    return data
}

@Suite("Scroll stitching")
struct ScrollStitcherTests {
    let page = makePage(width: 320, height: 2400).makeImage()!

    private func stitch(offsets: [Int], height: Int = 400, header: Int = 0, footer: Int = 0) -> (CGImage, [ScrollStitcher.Update]) {
        var stitcher = ScrollStitcher()
        let updates = offsets.map { stitcher.add(frame(of: page, offset: $0, height: height, header: header, footer: footer)) }
        return (stitcher.makeImage()!, updates)
    }

    @Test func plainScrollRebuildsThePage() {
        let offsets = [0, 0, 37, 120, 121, 300, 520, 700]
        let (image, updates) = stitch(offsets: offsets)
        #expect(updates.first == .started)
        #expect(updates[1] == .unchanged)
        #expect(image.height == 700 + 400)
        let same = pixels(image) == pixels(page.copyRows(0 ..< 1100)!)
        #expect(same)
    }

    @Test func stickyHeaderAndFooterAppearOnce() {
        let (header, footer) = (44, 30)
        let offsets = [0, 60, 200, 333, 500]
        let (image, _) = stitch(offsets: offsets, header: header, footer: footer)
        let content = 400 - header - footer
        #expect(image.height == header + 500 + content + footer)
        // The page between the bars must be continuous and exact.
        let expected = frame(of: page, offset: 0, height: header + 500 + content + footer, header: header, footer: footer)
        let same = pixels(image) == pixels(expected)
        #expect(same)
    }

    @Test func blinkingCaretIsNotMistakenForScrolling() {
        var stitcher = ScrollStitcher()
        let header = 44
        let f = { (offset: Int, caret: Bool) in frame(of: page, offset: offset, height: 400, header: header, footer: 0, caret: caret) }
        #expect(stitcher.add(f(0, false)) == .started)
        #expect(stitcher.add(f(0, true)) == .unchanged)
        #expect(stitcher.add(f(0, false)) == .unchanged)
        #expect(stitcher.add(f(150, false)) == .appended(150))
        // The fixed header must still have been measured on the real scroll.
        let image = stitcher.makeImage()!
        let same = pixels(image) == pixels(frame(of: page, offset: 0, height: 550, header: header, footer: 0))
        #expect(same)
    }

    @Test func floatingOverlayOverPartOfTheAreaStillStitches() {
        // Like a notification banner over the top-right corner: it stays put while the page moves.
        func covered(_ offset: Int) -> CGImage {
            let base = frame(of: page, offset: offset, height: 400, header: 0, footer: 0)
            let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
            ctx.fill(CGRect(x: base.width / 2, y: base.height - 60, width: base.width / 2, height: 50))
            return ctx.makeImage()!
        }
        var stitcher = ScrollStitcher()
        #expect(stitcher.add(covered(0)) == .started)
        #expect(stitcher.add(covered(120)) == .appended(120))
        #expect(stitcher.add(covered(260)) == .appended(140))
    }

    @Test func movingOverlayWithoutScrollingIsNotAWarning() {
        // A pointer or banner moving over a still page: changed, but no scroll and nothing lost.
        func withBlob(at y: Int) -> CGImage {
            let base = frame(of: page, offset: 0, height: 400, header: 0, footer: 0)
            let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(base, in: CGRect(x: 0, y: 0, width: base.width, height: base.height))
            ctx.setFillColor(CGColor(red: 1, green: 0.6, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 120, y: y, width: 40, height: 60))
            return ctx.makeImage()!
        }
        var stitcher = ScrollStitcher()
        #expect(stitcher.add(withBlob(at: 100)) == .started)
        #expect(stitcher.add(withBlob(at: 180)) == .unchanged)
        #expect(stitcher.add(withBlob(at: 260)) == .unchanged)
    }

    @Test func scrollingTooFarAtOnceIsReportedNotGuessed() {
        let (image, updates) = stitch(offsets: [0, 600])
        #expect(updates.last == .lost)
        #expect(image.height == 400)
    }

    @Test func scrollingUpDoesNotGrowTheImage() {
        let (image, updates) = stitch(offsets: [0, 200, 100])
        #expect(updates.last == .lost)
        #expect(image.height == 600)
    }
}
