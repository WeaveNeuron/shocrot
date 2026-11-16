import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import Shocrot

@Suite("Image files")
struct ImageFileTests {
    /// 40×20 pixels, white with a red 10×10 block in the top-left corner, saved as a JPEG with this EXIF orientation.
    private func photo(orientation: Int, dpi: Double = 72) throws -> URL {
        let ctx = try #require(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 10, width: 10, height: 10)) // y-up: top-left
        let image = try #require(ctx.makeImage())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shocrot-test-\(UUID().uuidString).jpg")
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyOrientation: orientation, kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// Red at pixel (x, y), counted from the top-left.
    private func isRed(_ image: CGImage, _ x: Int, _ y: Int) -> Bool {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height))
        return px[0] > 200 && px[1] < 80 && px[2] < 80
    }

    @Test func uprightFileIsReadAsIs() throws {
        let url = try photo(orientation: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let (image, scale) = try #require(ImageFile.load(url))
        #expect(image.width == 40 && image.height == 20)
        #expect(scale == 1)
        #expect(isRed(image, 2, 2))
    }

    @Test func phonePortraitPhotoIsTurnedUpright() throws {
        // Orientation 6: the stored top-left shows at the top-right once rotated 90° clockwise.
        let url = try photo(orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let (image, _) = try #require(ImageFile.load(url))
        #expect(image.width == 20 && image.height == 40)
        #expect(isRed(image, 17, 2))
        #expect(!isRed(image, 2, 2))
    }

    @Test func dpiSetsTheScale() throws {
        let url = try photo(orientation: 1, dpi: 144)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(ImageFile.load(url)?.1 == 2)
    }
}
