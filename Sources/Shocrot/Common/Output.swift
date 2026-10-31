import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum ImageOutput {
    static func data(_ image: CGImage, format: ImageFormat) -> Data? {
        let rep = NSBitmapImageRep(cgImage: image)
        switch format {
        case .png: return rep.representation(using: .png, properties: [:])
        case .jpeg: return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
        }
    }

    static func nsImage(_ image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }

    static func copy(_ image: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = data(image, format: .png) { item.setData(png, forType: .png) }
        if let tiff = nsImage(image, scale: scale).tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
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

    /// Quick-save into the configured folder. Returns the written URL.
    @discardableResult
    static func save(_ image: CGImage) throws -> URL {
        let settings = Settings.shared
        let dir = settings.saveDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(timestampName).appendingPathExtension(settings.imageFormat.ext)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(timestampName) (\(n))").appendingPathExtension(settings.imageFormat.ext)
            n += 1
        }
        guard let data = data(image, format: settings.imageFormat) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
        return url
    }

    static func saveAs(_ image: CGImage) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = timestampName + "." + Settings.shared.imageFormat.ext
        panel.directoryURL = Settings.shared.saveDirectory
        panel.canCreateDirectories = true
        NSApp.activate()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let format: ImageFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .png
            do {
                try data(image, format: format)?.write(to: url)
                Feedback.toast("已保存到 \(url.lastPathComponent)", symbol: "checkmark.circle.fill")
            } catch {
                Feedback.error(error)
            }
        }
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
