import AppKit
import Vision

struct OCRLine: Identifiable {
    let id = UUID()
    let text: String
    let confidence: Float
    /// Normalized Vision bounding box (origin bottom-left, 0...1).
    let box: CGRect
}

struct OCRResult {
    let lines: [OCRLine]
    let barcodes: [String]

    /// Joins recognized lines: lines on the same visual row share a line, and a large vertical gap
    /// starts a new paragraph. `keepLineBreaks: false` reflows wrapped lines within a paragraph
    /// (for copying and translation).
    func text(keepLineBreaks: Bool) -> String {
        var out = ""
        var previous: OCRLine?
        for line in lines {
            if let p = previous {
                let sameRow = abs(p.box.midY - line.box.midY) < min(p.box.height, line.box.height) * 0.5
                let newParagraph = p.box.minY - line.box.maxY > max(p.box.height, line.box.height) * 0.9
                if sameRow {
                    out += "  "
                } else if newParagraph {
                    out += "\n\n"
                } else if keepLineBreaks {
                    out += "\n"
                } else if out.hasSuffix("-"), out.dropLast().last?.isLetter == true, line.text.first?.isLowercase == true {
                    out.removeLast()  // re-join a word hyphenated across lines
                } else if let last = out.last, let first = line.text.first, !(last.isCJK || first.isCJK), last != " " {
                    out += " "
                }
            }
            out += line.text
            previous = line
        }
        return out
    }
}

/// A text recognizer. Other engines (cloud OCR, vision LLMs, PaddleOCR…) plug in by conforming
/// to this protocol and being assigned to `OCRService.engine`.
protocol OCREngine {
    var name: String { get }
    func recognize(_ image: CGImage, languages: [String]) async throws -> OCRResult
}

enum OCRService {
    static var engine: OCREngine = VisionOCREngine()

    static func recognize(_ image: CGImage, languages: [String]) async throws -> OCRResult {
        try await engine.recognize(image, languages: languages)
    }
}

/// Apple Vision, on-device.
struct VisionOCREngine: OCREngine {
    let name = "Apple Vision"

    func recognize(_ image: CGImage, languages: [String]) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try Self.recognizeSync(image, languages: languages) })
            }
        }
    }

    /// Vision loads its text models lazily, which makes the first recognition slow.
    /// Run a throwaway request in the background at launch so the first real one is instant.
    static func warmUp(languages: [String]) {
        DispatchQueue.global(qos: .utility).async {
            let size = 64
            guard let ctx = CGContext(data: nil, width: size * 4, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: size * 4, height: size))
            let font = CTFontCreateWithName("PingFang SC" as CFString, 28, nil)
            let text = NSAttributedString(string: "Shocrot 截图", attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            ctx.textPosition = CGPoint(x: 8, y: 20)
            CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
            if let image = ctx.makeImage() { _ = try? recognizeSync(image, languages: languages) }
        }
    }

    static func recognizeSync(_ image: CGImage, languages: [String]) throws -> OCRResult {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = languages.isEmpty
        if !languages.isEmpty {
            let supported = (try? textRequest.supportedRecognitionLanguages()) ?? []
            textRequest.recognitionLanguages = languages.filter { supported.contains($0) }
        }
        let barcodeRequest = VNDetectBarcodesRequest()

        // Tiny selections recognize much better when upscaled.
        let input = image.width < 600 || image.height < 120 ? (image.upscaled(by: 2) ?? image) : image
        let handler = VNImageRequestHandler(cgImage: input, options: [:])
        try handler.perform([textRequest, barcodeRequest])

        let observations = textRequest.results ?? []
        var lines: [OCRLine] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return OCRLine(text: candidate.string, confidence: candidate.confidence, box: obs.boundingBox)
        }
        // Reading order: top to bottom, then left to right within a row.
        lines.sort { a, b in
            if abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5 {
                return a.box.minX < b.box.minX
            }
            return a.box.midY > b.box.midY
        }
        let codes = (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
        return OCRResult(lines: lines, barcodes: Array(NSOrderedSet(array: codes)) as? [String] ?? codes)
    }
}

extension Character {
    var isCJK: Bool {
        guard let scalar = unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3000...0x303F, 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default:
            return false
        }
    }
}

extension CGImage {
    func upscaled(by factor: CGFloat) -> CGImage? {
        let w = Int(CGFloat(width) * factor), h = Int(CGFloat(height) * factor)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(self, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
