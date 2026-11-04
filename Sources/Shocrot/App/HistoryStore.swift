import AppKit

struct HistoryItem: Codable, Identifiable, Equatable {
    let id: UUID
    let date: Date
    let fileName: String
    let scale: CGFloat
    var text: String?   // OCR result, if any
    let pixelSize: CGSize
}

/// Keeps recent captures (and OCR text) in ~/Library/Application Support/Shocrot/History.
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    static let limit = 200

    @Published private(set) var items: [HistoryItem] = []
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private let queue = DispatchQueue(label: "shocrot.history", qos: .utility)

    private convenience init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.init(directory: support.appendingPathComponent("Shocrot/History", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([HistoryItem].self, from: data) {
                items = decoded
            } else {
                // Don't let the next save overwrite the index and orphan every image.
                try? FileManager.default.removeItem(at: directory.appendingPathComponent("index.corrupt.json"))
                try? FileManager.default.moveItem(at: indexURL, to: directory.appendingPathComponent("index.corrupt.json"))
                items = Self.rebuildItems(in: directory)
                persist()
            }
        }
    }

    /// Recovers the list from the images themselves; only the OCR text is lost.
    static func rebuildItems(in directory: URL) -> [HistoryItem] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let items = files.compactMap { url -> HistoryItem? in
            guard url.pathExtension == "png", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                  let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
            let date = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let dpi = props[kCGImagePropertyDPIWidth] as? CGFloat
            return HistoryItem(id: id, date: date, fileName: url.lastPathComponent,
                               scale: dpi.map { max(1, ($0 / 72).rounded()) } ?? (NSScreen.main?.backingScaleFactor ?? 2),
                               text: nil, pixelSize: CGSize(width: w, height: h))
        }
        return items.sorted { $0.date > $1.date }
    }

    func url(for item: HistoryItem) -> URL { directory.appendingPathComponent(item.fileName) }

    func image(for item: HistoryItem) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url(for: item) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    func thumbnail(for item: HistoryItem, maxPixel: Int = 480) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url(for: item) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxPixel,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    @discardableResult
    func add(_ image: CGImage, scale: CGFloat, text: String? = nil) -> UUID? {
        guard Settings.shared.keepHistory else { return nil }
        let id = UUID()
        let item = HistoryItem(id: id, date: Date(), fileName: "\(id.uuidString).png", scale: scale, text: text,
                               pixelSize: CGSize(width: image.width, height: image.height))
        let url = url(for: item)
        queue.async {
            let result = Result {
                guard let data = ImageOutput.data(image, format: .png, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url, options: .atomic)
            }
            DispatchQueue.main.async { self.finishAdding(id, result) }
        }
        items.insert(item, at: 0)
        persist()
        return id
    }

    /// Older captures make room only once the new one is safely on disk.
    private func finishAdding(_ id: UUID, _ result: Result<Void, Error>) {
        switch result {
        case .success:
            objectWillChange.send() // refresh thumbnails
            guard items.count > HistoryStore.limit else { return }
            trim()
            persist()
        case let .failure(error):
            items.removeAll { $0.id == id }
            persist()
            Feedback.error(error)
        }
    }

    /// Blocks until queued file and index writes are on disk.
    func finishPendingWrites() {
        queue.sync {}
    }

    func setText(_ text: String, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text
        persist()
    }

    /// Removal shares the writer's queue, so it can't overtake a write that is still pending.
    private func removeFile(of item: HistoryItem) {
        let url = url(for: item)
        queue.async { try? FileManager.default.removeItem(at: url) }
    }

    func delete(_ item: HistoryItem) {
        removeFile(of: item)
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.forEach(removeFile)
        items.removeAll()
        persist()
    }

    private func trim() {
        while items.count > HistoryStore.limit, let last = items.popLast() {
            removeFile(of: last)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let snapshot = items
        let url = indexURL
        queue.async { try? encoder.encode(snapshot).write(to: url, options: .atomic) }
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }
}
