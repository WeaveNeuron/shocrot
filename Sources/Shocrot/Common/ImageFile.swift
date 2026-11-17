import CoreGraphics
import Foundation
import ImageIO

/// Reads image files the way they are meant to be seen.
enum ImageFile {
    /// The image upright (EXIF orientation applied, as photos from a phone need) and its pixels-per-point scale
    /// taken from the file's DPI (1×–3×).
    static func load(_ url: URL) -> (CGImage, CGFloat)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        guard let image = upright(src, properties: props) else { return nil }
        let dpi = (props?[kCGImagePropertyDPIWidth] as? NSNumber).map { CGFloat($0.doubleValue) } ?? 72
        return (image, scale(forDPI: dpi))
    }

    /// Pixels per point for a file's DPI, kept to what screens use (1×–3×): a 300 DPI scan would otherwise
    /// show at a quarter of its pixel size.
    static func scale(forDPI dpi: CGFloat) -> CGFloat {
        guard dpi.isFinite, dpi > 0 else { return 1 }
        return min(3, max(1, (dpi / 72).rounded()))
    }

    private static func upright(_ src: CGImageSource, properties props: [CFString: Any]?) -> CGImage? {
        let orientation = (props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard orientation != 1,
              let w = (props?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue else {
            // Already upright: decode as is, pixel for pixel.
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        // Full size, rotated and mirrored as the orientation says.
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(w, h),
        ] as CFDictionary) ?? CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}
