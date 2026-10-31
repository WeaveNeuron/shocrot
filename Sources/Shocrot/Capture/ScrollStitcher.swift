import CoreGraphics

/// Stitches successive captures of a scrolling region into one tall image.
///
/// Each frame is reduced to per-row signatures (block averages of a grayscale copy). A new frame is
/// matched against the previous one by voting on the vertical offset that lines up equal rows, then
/// verified row by row. Rows that stay put at the top and bottom (sticky toolbars, headers, footers)
/// are measured on the first movement and excluded from matching; the footer is added back once, at
/// the end. Only downward scrolling grows the image.
struct ScrollStitcher {
    enum Update: Equatable {
        case started            // first frame
        case appended(Int)      // new rows added
        case unchanged          // nothing moved
        case lost               // content changed but no overlap was found (scrolled too fast, or upward)
        case full               // reached `maxHeight`
    }

    let maxHeight: Int
    private(set) var height = 0 // rows of the stitched image so far

    private var first: CGImage?
    private var last: CGImage?
    private var slices: [CGImage] = []
    private var previous: Signatures?
    private var header = 0
    private var footer = 0
    private var edgesKnown = false

    init(maxHeight: Int = 30_000) {
        self.maxHeight = maxHeight
    }

    mutating func add(_ image: CGImage) -> Update {
        guard let sig = Signatures(image) else { return .unchanged }
        guard let prev = previous, let first, first.width == image.width, first.height == image.height else {
            first = image
            last = image
            previous = sig
            slices.removeAll()
            edgesKnown = false
            height = image.height
            return .started
        }
        if height >= maxHeight { return .full }

        let h = sig.rows
        let topSame = (0..<h).prefix { sig.equal($0, prev, $0) }.count
        if topSame == h { return .unchanged }
        if !edgesKnown {
            header = min(topSame, h / 3)
            footer = min((0..<h).reversed().prefix { sig.equal($0, prev, $0) }.count, h / 3)
            edgesKnown = true
        }

        guard let d = offset(of: sig, from: prev) else { return .lost }
        let bottom = h - footer
        guard let slice = image.copyRows(bottom - d ..< bottom) else { return .lost }
        slices.append(slice)
        height += d
        last = image
        previous = sig
        return height >= maxHeight ? .full : .appended(d)
    }

    /// The stitched image: the first frame above its footer, every new slice, then the footer.
    func makeImage() -> CGImage? {
        guard let first, let last else { return nil }
        if slices.isEmpty { return first }
        let width = first.width
        let total = height
        guard let ctx = CGContext(data: nil, width: width, height: total, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // Core Graphics draws bottom-up; walk down from the top edge.
        var top = total
        func place(_ image: CGImage) {
            top -= image.height
            ctx.draw(image, in: CGRect(x: 0, y: top, width: width, height: image.height))
        }
        if let head = first.copyRows(0 ..< first.height - footer) { place(head) }
        slices.forEach(place)
        if footer > 0, let foot = last.copyRows(last.height - footer ..< last.height) { place(foot) }
        return ctx.makeImage()
    }

    /// How far the content moved up between `prev` and `sig`, in rows.
    private func offset(of sig: Signatures, from prev: Signatures) -> Int? {
        let band = header ..< sig.rows - footer
        guard band.count > 8 else { return nil }

        var positions: [Int: [Int]] = [:]
        for y in band where prev.informative(y) {
            positions[prev.key(y), default: []].append(y)
        }
        var votes: [Int: Int] = [:]
        for y in band where sig.informative(y) {
            guard let matches = positions[sig.key(y)], matches.count <= 8 else { continue }
            for p in matches where p > y { votes[p - y, default: 0] += 1 }
        }

        // Best-voted offsets first; accept the first that holds up row by row.
        for (d, _) in votes.sorted(by: { $0.value > $1.value }).prefix(5) {
            var checked = 0, matched = 0
            for y in band.lowerBound ..< band.upperBound - d where sig.informative(y) {
                checked += 1
                if sig.equal(y, prev, y + d) { matched += 1 }
            }
            if checked >= 4 && Double(matched) >= Double(checked) * 0.9 { return d }
        }
        return nil
    }
}

/// Per-row block averages of a grayscale copy of a frame. Row 0 is the top.
private struct Signatures {
    static let blocks = 32
    let rows: Int
    let columns: Int
    private let values: [UInt8]

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        let drawn = gray.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        let columns = min(w, Self.blocks)
        var values = [UInt8](repeating: 0, count: h * columns)
        for y in 0..<h {
            let row = y * w
            for b in 0..<columns {
                let start = b * w / columns, end = (b + 1) * w / columns
                var sum = 0
                for x in start..<end { sum += Int(gray[row + x]) }
                values[y * columns + b] = UInt8(sum / max(end - start, 1))
            }
        }
        self.rows = h
        self.columns = columns
        self.values = values
    }

    /// Rows with some contrast; flat background rows match anything and would mislead the offset.
    func informative(_ y: Int) -> Bool {
        let row = values[y * columns ..< (y + 1) * columns]
        return (row.max() ?? 0) - (row.min() ?? 0) > 4
    }

    func equal(_ y: Int, _ other: Signatures, _ oy: Int) -> Bool {
        for b in 0..<columns where abs(Int(values[y * columns + b]) - Int(other.values[oy * columns + b])) > 3 {
            return false
        }
        return true
    }

    func key(_ y: Int) -> Int {
        var hasher = Hasher()
        for b in 0..<columns { hasher.combine(values[y * columns + b] >> 3) }
        return hasher.finalize()
    }
}

extension CGImage {
    /// An independent copy of a horizontal band (row 0 is the top), so the source frame can be released.
    func copyRows(_ range: Range<Int>) -> CGImage? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= height,
              let band = cropping(to: CGRect(x: 0, y: range.lowerBound, width: width, height: range.count)),
              let ctx = CGContext(data: nil, width: width, height: range.count, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(band, in: CGRect(x: 0, y: 0, width: width, height: range.count))
        return ctx.makeImage()
    }
}
