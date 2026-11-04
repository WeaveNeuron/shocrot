import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ImageOutput {
    /// `scale` is written as the file's DPI (144 for Retina), so other apps place it at its real size.
    static func data(_ image: CGImage, format: ImageFormat, scale: CGFloat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    /// The capture on a soft gradient, with rounded corners and a drop shadow, ready to share.
    static func beautified(_ image: CGImage, scale: CGFloat) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = (min(max(min(w, h) / scale * 0.08, 32), 80) * scale).rounded()
        let radius = 10 * scale
        let size = CGSize(width: w + pad * 2, height: h + pad * 2)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let colors = [CGColor(srgbRed: 0.56, green: 0.77, blue: 0.99, alpha: 1),
                      CGColor(srgbRed: 0.88, green: 0.76, blue: 0.99, alpha: 1)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])
        }
        let card = CGRect(x: pad, y: pad, width: w, height: h)
        let path = CGPath(roundedRect: card, cornerWidth: radius, cornerHeight: radius, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 28 * scale,
                      color: CGColor(gray: 0, alpha: 0.28))
        ctx.addPath(path)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.draw(image, in: card)
        return ctx.makeImage()
    }

    enum Transform { case rotateRight, rotateLeft, flipHorizontal, flipVertical }

    /// A rotated or mirrored copy, pixel for pixel.
    static func transformed(_ image: CGImage, _ t: Transform) -> CGImage? {
        let w = image.width, h = image.height
        let turns = t == .rotateRight || t == .rotateLeft
        let (ow, oh) = turns ? (h, w) : (w, h)
        guard let ctx = CGContext(data: nil, width: ow, height: oh, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        // Core Graphics is y-up, so a clockwise turn on screen is a negative angle here.
        switch t {
        case .rotateRight: ctx.translateBy(x: 0, y: CGFloat(oh)); ctx.rotate(by: -.pi / 2)
        case .rotateLeft: ctx.translateBy(x: CGFloat(ow), y: 0); ctx.rotate(by: .pi / 2)
        case .flipHorizontal: ctx.translateBy(x: CGFloat(ow), y: 0); ctx.scaleBy(x: -1, y: 1)
        case .flipVertical: ctx.translateBy(x: 0, y: CGFloat(oh)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Puts a file on the clipboard, to paste into Finder, chats or mail.
    static func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
    }

    /// Lets tests observe when clipboard data is really encoded.
    nonisolated(unsafe) static var onClipboardEncode: (NSPasteboard.PasteboardType) -> Void = { _ in }

    /// Encoding a full screen takes ~200 ms and the TIFF is ~60 MB, so both are made only when an app asks.
    static func copy(_ image: CGImage, scale: CGFloat, to pb: NSPasteboard = .general) {
        pb.clearContents()
        let item = NSPasteboardItem()
        let provider = ClipboardImage(image: image, scale: scale, onEncode: onClipboardEncode)
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        pb.writeObjects([item])
        if pb == .general { ClipboardImage.current = provider }
    }

    /// Promised clipboard data dies with the process; hand it over before quitting.
    static func resolveClipboard() {
        guard ClipboardImage.current != nil else { return }
        _ = NSPasteboard.general.data(forType: .png)
        _ = NSPasteboard.general.data(forType: .tiff)
    }

    /// Renders text as a light note card (for pinning copied text). Long text wraps at a readable width.
    static func textImage(_ text: String, scale: CGFloat, maxWidth: CGFloat = 520) -> CGImage? {
        let font = NSFont.systemFont(ofSize: 14)
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 3
        let string = NSAttributedString(string: String(text.prefix(4000)), attributes: [
            .font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: style,
        ])
        let padding: CGFloat = 14
        let bounds = string.boundingRect(with: CGSize(width: maxWidth, height: 4000),
                                         options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(bounds.width) + padding * 2, height: min(ceil(bounds.height), 4000) + padding * 2)
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        ctx.setFillColor(CGColor(red: 1, green: 0.99, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        string.draw(with: CGRect(x: padding, y: padding, width: maxWidth, height: size.height - padding * 2),
                    options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    static func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static var timestampName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Shocrot \(f.string(from: Date()))"
    }

    /// A timestamped file name in `dir` that doesn't exist yet.
    static func uniqueURL(in dir: URL, ext: String) -> URL {
        let name = timestampName
        var url = dir.appendingPathComponent(name).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(name) (\(n))").appendingPathExtension(ext)
            n += 1
        }
        return url
    }

    /// One at a time: choosing a free name and writing the file must not interleave with another save.
    private static let saveQueue = DispatchQueue(label: "shocrot.save", qos: .userInitiated)

    static func save(_ image: CGImage, scale: CGFloat, format: ImageFormat, in dir: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            saveQueue.async {
                cont.resume(with: Result {
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    guard let encoded = data(image, format: format, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
                    let url = uniqueURL(in: dir, ext: format.ext)
                    try encoded.write(to: url, options: .withoutOverwriting)
                    return url
                })
            }
        }
    }

    /// Quick-save into the configured folder. Returns the written URL.
    @MainActor
    static func saveInBackground(_ image: CGImage, scale: CGFloat) async throws -> URL {
        let settings = Settings.shared
        return try await save(image, scale: scale, format: settings.imageFormat, in: settings.saveDirectory)
    }

    /// Blocks until the saves requested so far are on disk.
    static func finishPendingSaves() {
        saveQueue.sync {}
    }

    static func saveAs(_ image: CGImage, scale: CGFloat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = timestampName + "." + Settings.shared.imageFormat.ext
        panel.directoryURL = Settings.shared.saveDirectory
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { response in
            FocusReturn.windowDidGoAway()
            guard response == .OK, let url = panel.url else { return }
            let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
            do {
                guard let encoded = data(image, format: format, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
                try encoded.write(to: url)
                Feedback.toast("已保存到 \(url.lastPathComponent)", symbol: "checkmark.circle.fill")
            } catch {
                Feedback.error(error)
            }
        }
    }
}

/// Encodes the copied image on demand, for whichever format the pasting app asks for.
final class ClipboardImage: NSObject, NSPasteboardItemDataProvider {
    static var current: ClipboardImage?

    private let image: CGImage
    private let scale: CGFloat
    private let onEncode: (NSPasteboard.PasteboardType) -> Void

    init(image: CGImage, scale: CGFloat, onEncode: @escaping (NSPasteboard.PasteboardType) -> Void = { _ in }) {
        self.image = image
        self.scale = scale
        self.onEncode = onEncode
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        onEncode(type)
        if type == .png, let png = ImageOutput.data(image, format: .png, scale: scale) {
            item.setData(png, forType: .png)
        } else if type == .tiff, let tiff = ImageOutput.nsImage(image, scale: scale).tiffRepresentation {
            item.setData(tiff, forType: .tiff)
        }
    }

    func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
        if ClipboardImage.current === self { ClipboardImage.current = nil }
    }
}

enum Feedback {
    static func shutter() {
        guard Settings.shared.playSound else { return }
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        if let sound = NSSound(contentsOfFile: path, byReference: true) { sound.play() } else { NSSound(named: "Tink")?.play() }
    }

    static func error(_ error: Error) {
        toast(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
    }

    private static var toastPanel: NSPanel?
    private static var toastWork: DispatchWorkItem?

    /// Removes the toast at once, e.g. before the screen is captured.
    static func hideToast() {
        toastWork?.cancel()
        toastPanel?.orderOut(nil)
        toastPanel = nil
    }

    /// A small HUD message near the top of the screen under the mouse.
    static func toast(_ message: String, symbol: String = "checkmark.circle.fill") {
        toastWork?.cancel()
        toastPanel?.orderOut(nil)

        let host = NSHostingView(rootView: ToastView(message: message, symbol: symbol))
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = CGRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.maxY - size.height - 24,
                           width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = host
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; panel.animator().alphaValue = 1 }
        toastPanel = panel

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 }) {
                panel.orderOut(nil)
            }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

private struct ToastView: View {
    let message: String
    let symbol: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(symbol.contains("exclamation") ? Color.orange : Color.green)
            Text(message)
                .lineLimit(2)
                .frame(maxWidth: 360, alignment: .leading)
        }
        .font(.system(size: 13, weight: .medium))
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
        .padding(12)
        .fixedSize()
    }
}
