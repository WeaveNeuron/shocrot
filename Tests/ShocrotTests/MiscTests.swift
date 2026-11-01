import Carbon.HIToolbox
import Testing
@testable import Shocrot

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func displayStringOrdersModifiersLikeMacOS() {
        let hk = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))
        #expect(hk.displayString == "⌥⇧A")
        let all = HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(all.displayString == "⌃⌥⇧⌘X")
    }

    @Test func keyCapsKeepMultiCharacterKeysWhole() {
        #expect(KeyCaps.parts(of: "⌥⇧A") == ["⌥", "⇧", "A"])
        #expect(KeyCaps.parts(of: "⌥F12") == ["⌥", "F12"])
        #expect(KeyCaps.parts(of: "F5") == ["F5"])
        #expect(KeyCaps.parts(of: "—") == ["—"])
    }
}

@Suite("Language")
struct LanguageTests {
    @Test func detectsCommonLanguages() {
        #expect(Language.detect("Screenshots are the fastest way to share what you see.")?.code == "en")
        #expect(Language.detect("一个按键，截图、标注、贴图、识别与翻译。")?.code == "zh-Hans")
        #expect(Language.detect("スクリーンショットを撮って翻訳します。")?.code == "ja")
    }

    @Test func unknownCodesFallBackToTheCode() {
        #expect(Language.named("xx").name == "xx")
        #expect(Language.named("zh-Hans").name == "简体中文")
    }
}

@Suite("Pinned text")
struct PinnedTextTests {
    @Test func shortTextMakesACompactCard() throws {
        let image = try #require(ImageOutput.textImage("Hello", scale: 2))
        #expect(image.width < 200 && image.height < 120)
    }

    @Test func longTextWrapsAtTheMaximumWidth() throws {
        let text = String(repeating: "Shocrot pins copied text as a note. ", count: 40)
        let image = try #require(ImageOutput.textImage(text, scale: 1, maxWidth: 400))
        #expect(image.width <= 400 + 28)
        #expect(image.height > 100)
    }
}

@Suite("Beautify")
struct BeautifyTests {
    private func solid(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (p[0], p[1], p[2])
    }

    @Test func padsEvenlyAndKeepsTheCaptureSharp() throws {
        let out = try #require(ImageOutput.beautified(solid(800, 400), scale: 2))
        // 8% of the short side (200 pt) is 16 pt, clamped up to 32 pt = 64 px per edge.
        #expect(out.width == 800 + 128)
        #expect(out.height == 400 + 128)
        let center = pixel(out, out.width / 2, out.height / 2)
        #expect(center.r == 255 && center.g == 0 && center.b == 0)
        let corner = pixel(out, 2, 2) // background gradient, not the capture
        #expect(corner.b > 200 && corner.r < 200)
    }

    @Test func paddingIsCappedForLargeCaptures() throws {
        let out = try #require(ImageOutput.beautified(solid(4000, 3000), scale: 1))
        #expect(out.width == 4000 + 160)
    }
}

@Suite("Pin transforms")
struct TransformTests {
    /// 2×1: red on the left, blue on the right.
    private let source: CGImage = {
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        return ctx.makeImage()!
    }()

    /// "r" or "b" for each pixel, row by row from the top.
    private func layout(_ image: CGImage) -> [String] {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (0..<h).map { y in String((0..<w).map { x in px[(y * w + x) * 4] > 128 ? "r" : "b" }) }
    }

    @Test func rotationsAndFlipsPutPixelsWhereExpected() throws {
        #expect(layout(source) == ["rb"])
        #expect(layout(try #require(ImageOutput.transformed(source, .rotateRight))) == ["r", "b"])
        #expect(layout(try #require(ImageOutput.transformed(source, .rotateLeft))) == ["b", "r"])
        #expect(layout(try #require(ImageOutput.transformed(source, .flipHorizontal))) == ["br"])
        let tall = try #require(ImageOutput.transformed(source, .rotateRight))
        #expect(layout(try #require(ImageOutput.transformed(tall, .flipVertical))) == ["b", "r"])
    }
}
