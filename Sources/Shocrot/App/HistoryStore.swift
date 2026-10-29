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

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = support.appendingPathComponent("Shocrot/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
        }
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
            guard let data = ImageOutput.data(image, format: .png) else { return }
            try? data.write(to: url)
            DispatchQueue.main.async { self.objectWillChange.send() } // refresh thumbnails
        }
        items.insert(item, at: 0)
        trim()
        persist()
        return id
    }

    func setText(_ text: String, for id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].text = text
        persist()
    }

    func delete(_ item: HistoryItem) {
        try? FileManager.default.removeItem(at: url(for: item))
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.forEach { try? FileManager.default.removeItem(at: url(for: $0)) }
        items.removeAll()
        persist()
    }

    private func trim() {
        while items.count > HistoryStore.limit, let last = items.popLast() {
            try? FileManager.default.removeItem(at: url(for: last))
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
