import CoreGraphics
import Testing
@testable import Shocrot

@Suite("OCR warm-up")
struct OCRWarmUpTests {
    @Test func warmUpImageHasBilingualDimensionsWithoutUpscaling() throws {
        let image = try #require(VisionOCREngine.warmUpImage(for: []))
        #expect(image.width == 640 && image.height == 200)
        // Must not trigger 2× upscaling during background warm-up.
        #expect(!VisionOCREngine.shouldUpscale(width: image.width, height: image.height))
    }

    @Test func warmUpImageSupportsExtraLanguages() throws {
        let img = try #require(VisionOCREngine.warmUpImage(for: ["ja-JP", "ko-KR"]))
        #expect(img.width == 640 && img.height == 200)
    }

    @Test func recognizeSyncReadsWarmUpImageWithoutBarcodes() throws {
        let image = try #require(VisionOCREngine.warmUpImage(for: []))
        let result = try VisionOCREngine.recognizeSync(image, languages: [], detectBarcodes: false)
        let text = result.text(keepLineBreaks: true)
        #expect(result.lines.count >= 2)
        #expect(text.contains("macOS") || text.contains("recognition"))
        #expect(text.contains("中文") || text.contains("预热"))
        #expect(result.barcodes.isEmpty)
    }
}
