import AppKit
import os
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
    /// (for copying and translation) but keeps headings, list items, short lines and indented
    /// paragraphs apart, following the layout cues Easydict uses. (Vision's box heights are too
    /// noisy to detect font size changes, so headings are caught as short lines.)
    func text(keepLineBreaks: Bool) -> String {
        let left = lines.map(\.box.minX).min() ?? 0
        let right = lines.map(\.box.maxX).max() ?? 1
        let width = max(right - left, .ulpOfOne)
        // Poems and similar blocks: every line starts with a capital letter.
        let allCapitalized = lines.count >= 3 && lines.allSatisfy { $0.text.first?.isUppercase == true }

        var out = ""
        var previous: OCRLine?
        for line in lines {
            if let p = previous {
                let sameRow = abs(p.box.midY - line.box.midY) < min(p.box.height, line.box.height) * 0.5
                let gap = p.box.minY - line.box.maxY
                if sameRow {
                    out += "  "
                } else if gap > max(p.box.height, line.box.height) * 0.9 {
                    out += "\n\n"
                } else if keepLineBreaks || allCapitalized || line.text.startsListItem
                            || p.box.maxX < right - width * 0.2          // previous line ends early
                            || line.box.minX > left + width * 0.03 {     // indented first line
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

private extension String {
    /// "• item", "- item", "1. step", "2) step", "(3) step", "① step".
    var startsListItem: Bool {
        guard let first = first else { return false }
        if "•·▪◦‣-–—*※①②③④⑤⑥⑦⑧⑨⑩".contains(first) { return true }
        return range(of: #"^\(?[0-9]{1,2}[.)、]"#, options: .regularExpression) != nil
    }
}

/// A text recognizer. Other engines (cloud OCR, vision LLMs, PaddleOCR…) plug in by conforming
/// to this protocol and being assigned to `OCRService.engine`.
protocol OCREngine {
    var name: String { get }
    func recognize(_ image: CGImage, languages: [String], detectBarcodes: Bool) async throws -> OCRResult
}

extension OCREngine {
    func recognize(_ image: CGImage, languages: [String]) async throws -> OCRResult {
        try await recognize(image, languages: languages, detectBarcodes: true)
    }
}

enum OCRService {
    static var engine: OCREngine = VisionOCREngine()

    static func recognize(_ image: CGImage, languages: [String], detectBarcodes: Bool = true) async throws -> OCRResult {
        try await engine.recognize(image, languages: languages, detectBarcodes: detectBarcodes)
    }
}

/// Apple Vision, on-device.
struct VisionOCREngine: OCREngine {
    let name = "Apple Vision"

    private struct WarmUpState {
        var pendingWork: DispatchWorkItem?
        var inFlight = false
        var warmedLanguages: [String]?
    }

    private static let warmUpLock = OSAllocatedUnfairLock(initialState: WarmUpState())
    private static let warmUpQueue = DispatchQueue(label: "shocrot.ocr.warmup", qos: .utility)
    private static let supportedLanguages: Set<String> = {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        return Set((try? req.supportedRecognitionLanguages()) ?? [])
    }()

    /// True while a background warm-up pass is currently executing (e.g. first-ever model compilation).
    static var isWarmingUp: Bool {
        warmUpLock.withLock { $0.inFlight }
    }

    func recognize(_ image: CGImage, languages: [String], detectBarcodes: Bool) async throws -> OCRResult {
        // Real user OCR cancels any not-yet-started idle warm-up so it doesn't compete with this capture.
        Self.cancelPendingWarmUp()
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result {
                    let result = try Self.recognizeSync(image, languages: languages, detectBarcodes: detectBarcodes)
                    Self.markWarmed(languages: languages)
                    return result
                })
            }
        }
    }

    /// Cancels a scheduled warm-up that hasn't started yet.
    static func cancelPendingWarmUp() {
        warmUpLock.withLock { state in
            state.pendingWork?.cancel()
            state.pendingWork = nil
        }
    }

    private static func markWarmed(languages: [String]) {
        warmUpLock.withLock { state in
            state.warmedLanguages = languages
        }
    }

    /// Schedules a lightweight background warm-up after `delay` seconds of launch/settings idle time.
    /// Using a medium bilingual multi-line image warms both Latin and CJK Vision recognition models without
    /// blocking launch, eliminating the ~150 ms cold penalty on the first real capture.
    static func warmUp(languages: [String], delay: TimeInterval = 0.4) {
        let work = DispatchWorkItem {
            let shouldRun = warmUpLock.withLock { state -> Bool in
                if state.warmedLanguages == languages { return false }
                state.pendingWork = nil
                state.inFlight = true
                return true
            }
            guard shouldRun else { return }
            defer {
                warmUpLock.withLock { state in
                    state.inFlight = false
                    state.warmedLanguages = languages
                }
            }
            let t0 = PerfLog.now()
            let sp = PerfLog.signposter.beginInterval("OCR.warmUp")
            defer {
                PerfLog.signposter.endInterval("OCR.warmUp", sp)
                let ms = PerfLog.elapsedMs(since: t0)
                PerfLog.logger.notice("ocr.warmup done_ms=\(ms, format: .fixed(precision: 1), privacy: .public) since_launch_ms=\(PerfLog.msSinceLaunch, format: .fixed(precision: 1), privacy: .public)")
            }
            if let image = warmUpImage(for: languages) {
                _ = try? recognizeSync(image, languages: languages, detectBarcodes: true)
            }
        }
        warmUpLock.withLock { state in
            state.pendingWork?.cancel()
            guard state.warmedLanguages != languages else { return }
            state.pendingWork = work
            if delay > 0 {
                warmUpQueue.asyncAfter(deadline: .now() + delay, execute: work)
            } else {
                warmUpQueue.async(execute: work)
            }
        }
    }

    /// Builds a medium bilingual multi-line image (640×200, no upscaling needed) so Vision's automatic language
    /// detector loads both Latin and CJK recognition models during warm-up. A single short mixed line (the old
    /// 256×64 sample) only warmed one script and left the first real capture ~2.5× slower.
    static func warmUpImage(for languages: [String]) -> CGImage? {
        let width = 640, height = 200
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 22, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]
        var lines = [
            "Modern macOS screenshot text recognition warm up.",
            "中文文字识别预热示例：涵盖常见汉字与标点。",
        ]
        if languages.contains("ja-JP") { lines.append("日本語のテキスト認識ウォームアップ。") }
        if languages.contains("ko-KR") { lines.append("한국어 텍스트 인식 준비.") }
        var y = CGFloat(height) - 42
        for line in lines.prefix(4) {
            ctx.textPosition = CGPoint(x: 16, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attrs)), ctx)
            y -= 40
        }
        return ctx.makeImage()
    }

    static func recognizeSync(_ image: CGImage, languages: [String], detectBarcodes: Bool = true) throws -> OCRResult {
        let tTotal = PerfLog.now()
        let spState = PerfLog.signposter.beginInterval("OCR.recognize")
        let tUp = PerfLog.now()
        let input = shouldUpscale(width: image.width, height: image.height) ? (image.upscaled(by: 2) ?? image) : image
        let upscaleMs = PerfLog.elapsedMs(since: tUp)
        var lines: [OCRLine] = []
        var codes: [String] = []
        var setupMs: Double = 0
        var performMs: Double = 0
        let filteredLanguages = languages.isEmpty ? [] : languages.filter { supportedLanguages.contains($0) }
        for band in bands(height: input.height) {
            guard let part = band.rows.count == input.height ? input
                    : input.cropping(to: CGRect(x: 0, y: band.rows.lowerBound, width: input.width, height: band.rows.count))
            else { continue }
            let tSetup = PerfLog.now()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            textRequest.automaticallyDetectsLanguage = filteredLanguages.isEmpty
            if !filteredLanguages.isEmpty {
                textRequest.recognitionLanguages = filteredLanguages
            }
            var requests: [VNRequest] = [textRequest]
            let barcodeRequest = detectBarcodes ? VNDetectBarcodesRequest() : nil
            if let barcodeRequest { requests.append(barcodeRequest) }
            setupMs += PerfLog.elapsedMs(since: tSetup)
            let tPerf = PerfLog.now()
            try VNImageRequestHandler(cgImage: part, options: [:]).perform(requests)
            performMs += PerfLog.elapsedMs(since: tPerf)

            for obs in textRequest.results ?? [] {
                guard let candidate = obs.topCandidates(1).first else { continue }
                let box = place(obs.boundingBox, in: band.rows, imageHeight: input.height)
                // Rows near a cut are seen by two bands; keep each line from the band that owns its middle.
                let middle = min(max(Int(((1 - box.midY) * CGFloat(input.height)).rounded(.down)), 0), input.height - 1)
                guard band.owns.contains(middle) else { continue }
                lines.append(OCRLine(text: candidate.string, confidence: candidate.confidence, box: box))
            }
            if let barcodeRequest {
                codes += (barcodeRequest.results ?? []).compactMap(\.payloadStringValue)
            }
        }
        let ordered = readingOrder(lines)
        let result = OCRResult(lines: ordered, barcodes: Array(NSOrderedSet(array: codes)) as? [String] ?? codes)
        PerfLog.signposter.endInterval("OCR.recognize", spState)
        let totalMs = PerfLog.elapsedMs(since: tTotal)
        PerfLog.logger.notice("ocr.recognize size=\(image.width, privacy: .public)x\(image.height, privacy: .public) barcodes=\(detectBarcodes, privacy: .public) upscale_ms=\(upscaleMs, format: .fixed(precision: 1), privacy: .public) setup_ms=\(setupMs, format: .fixed(precision: 1), privacy: .public) perform_ms=\(performMs, format: .fixed(precision: 1), privacy: .public) total_ms=\(totalMs, format: .fixed(precision: 1), privacy: .public) lines=\(ordered.count, privacy: .public) since_launch_ms=\(PerfLog.msSinceLaunch, format: .fixed(precision: 1), privacy: .public)")
        return result
    }
}

extension VisionOCREngine {
    struct Band: Equatable {
        /// Pixel rows of the image this band covers, counted from the top.
        let rows: Range<Int>
        /// The rows whose lines this band reports; the bands' `owns` ranges tile the image without overlap.
        let owns: Range<Int>
    }

    /// Vision reads an image at a reduced resolution, and past about 3,500 px of height most of the text is lost
    /// (a 1600 x 6000 page gave 16 of 120 lines, a 1600 x 30000 scrolling capture none at all). Taller images are
    /// read in bands of `bandHeight` rows that overlap by `bandOverlap`, so any line shorter than the overlap
    /// lies whole in one band.
    static let singlePassHeight = 3000, bandHeight = 2000, bandOverlap = 300

    static func bands(height: Int) -> [Band] {
        guard height > singlePassHeight else { return [Band(rows: 0 ..< height, owns: 0 ..< height)] }
        var rows: [Range<Int>] = []
        var start = 0
        while true {
            let end = min(start + bandHeight, height)
            rows.append(start ..< end)
            if end == height { break }
            start += bandHeight - bandOverlap
        }
        return rows.indices.map { i in
            let top = i == 0 ? 0 : rows[i].lowerBound + bandOverlap / 2
            let bottom = i == rows.count - 1 ? height : rows[i + 1].lowerBound + bandOverlap / 2
            return Band(rows: rows[i], owns: top ..< bottom)
        }
    }

    /// Maps a normalized box (origin bottom-left) within the band `rows` to the same kind of box in the whole image.
    static func place(_ box: CGRect, in rows: Range<Int>, imageHeight: Int) -> CGRect {
        guard rows.count != imageHeight else { return box }
        let band = CGFloat(rows.count), total = CGFloat(imageHeight)
        let bottomFromTop = CGFloat(rows.lowerBound) + (1 - box.minY) * band
        return CGRect(x: box.minX, y: 1 - bottomFromTop / total, width: box.width, height: box.height * band / total)
    }

    /// Tiny selections recognize much better at twice the size. A long strip that is narrow in only one direction
    /// (a column of a web page, say) already has enough pixels; doubling it quadruples the work for nothing.
    static func shouldUpscale(width: Int, height: Int) -> Bool {
        (width < 600 || height < 120) && width * height <= 1_000_000
    }

    /// Top to bottom, then left to right within a row. Lines are grouped into rows first: "on the same row" isn't
    /// transitive (A and B may share a row, B and C too, A and C not), so it can't serve as a sort comparator.
    /// A row is measured against its top line, so a slightly slanted page doesn't chain rows together.
    static func readingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let byHeight = lines.sorted { a, b in
            a.box.midY != b.box.midY ? a.box.midY > b.box.midY : a.box.minX < b.box.minX
        }
        var rows: [[OCRLine]] = []
        for line in byHeight {
            if let anchor = rows.last?.first,
               abs(anchor.box.midY - line.box.midY) < min(anchor.box.height, line.box.height) * 0.5 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX } }
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
