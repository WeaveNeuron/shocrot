import AppKit
import SwiftUI

/// Floating thumbnail shown in the corner after a capture, with quick follow-up actions.
/// Drag the thumbnail into any app to drop the image file.
enum CapturePreview {
    private static var panel: NSPanel?
    private static var dismissWork: DispatchWorkItem?
    private static var hovering = false
    private static weak var model: PreviewModel?

    static func show(image: CGImage, scale: CGFloat, status: String, savedURL: URL?, videoURL: URL? = nil,
                     on screen: NSScreen?) {
        // A recording always gets the card: it is the only way to reach the file and the GIF export.
        guard Settings.shared.showPreview || videoURL != nil else {
            Feedback.toast(status)
            return
        }
        close(animated: false)

        let model = PreviewModel(image: image, scale: scale, status: status, savedURL: savedURL)
        model.videoURL = videoURL
        CapturePreview.model = model
        let host = NSHostingView(rootView: PreviewCard(model: model) { hovering in
            CapturePreview.hovering = hovering
            if !hovering { scheduleDismiss(after: 3) }
        })
        let size = host.fittingSize
        let screen = screen ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.minX + 12, y: vf.minY + 12, width: size.width, height: size.height)

        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isReleasedWhenClosed = false
        p.contentView = host
        p.alphaValue = 0
        p.setFrameOrigin(CGPoint(x: frame.minX - 40, y: frame.minY))
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            p.animator().alphaValue = 1
            p.animator().setFrame(frame, display: true)
        }
        panel = p
        model.onClose = { close(animated: true) }
        hovering = false
        // A recording's card is the way to its file and the GIF export, so it stays longer.
        scheduleDismiss(after: videoURL == nil ? 6 : 15)
    }

    private static func scheduleDismiss(after seconds: Double) {
        dismissWork?.cancel()
        let work = DispatchWorkItem {
            if model?.isExporting == true { scheduleDismiss(after: 3) } else if !hovering { close(animated: true) }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func close(animated: Bool) {
        dismissWork?.cancel()
        guard let p = panel else { return }
        panel = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
            p.animator().setFrame(p.frame.offsetBy(dx: -30, dy: 0), display: true)
        }) { p.orderOut(nil) }
    }
}

final class PreviewModel: ObservableObject {
    let original: CGImage
    let scale: CGFloat
    @Published private(set) var image: CGImage
    @Published private(set) var thumbnail: NSImage
    @Published private(set) var isBeautified = false
    @Published var status: String
    @Published var savedURL: URL?
    @Published var isExporting = false
    var videoURL: URL?
    var onClose: () -> Void = {}
    private var tempURL: URL?

    init(image: CGImage, scale: CGFloat, status: String, savedURL: URL?) {
        original = image
        self.image = image
        self.scale = scale
        self.status = status
        self.savedURL = savedURL
        thumbnail = ImageOutput.nsImage(image, scale: scale)
    }

    /// Switches between the plain capture and the one on a gradient, and copies the result.
    func toggleBeautify() {
        let next = isBeautified ? original : ImageOutput.beautified(original, scale: scale)
        guard let next else { return }
        isBeautified.toggle()
        image = next
        thumbnail = ImageOutput.nsImage(next, scale: scale)
        savedURL = nil // the saved file is the other version
        tempURL = nil
        ImageOutput.copy(next, scale: scale)
        status = isBeautified ? "已美化并复制" : "已复制原图"
    }

    /// Writes a GIF next to the recording, then puts it on the clipboard as a file.
    func exportGIF() {
        guard let videoURL, !isExporting else { return }
        isExporting = true
        status = "正在生成 GIF…"
        Task { @MainActor in
            defer { isExporting = false }
            do {
                let gif = try await GIFExport.make(from: videoURL)
                ImageOutput.copyFile(gif)
                savedURL = gif
                tempURL = nil
                status = "已生成 GIF 并复制"
            } catch {
                status = "GIF 生成失败"
                Feedback.error(error)
            }
        }
    }

    /// A file for drag & drop: the saved file if any, otherwise a temporary PNG.
    var dragURL: URL? {
        if let savedURL { return savedURL }
        if let tempURL { return tempURL }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Shocrot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ImageOutput.timestampName).appendingPathExtension("png")
        guard let data = ImageOutput.data(image, format: .png), (try? data.write(to: url)) != nil else { return nil }
        tempURL = url
        return url
    }
}

private struct PreviewCard: View {
    @ObservedObject var model: PreviewModel
    let onHover: (Bool) -> Void
    @State private var hovering = false

    private var thumbSize: CGSize {
        // Sized from the original so the panel keeps its size when the beautified version is shown.
        let s = CGSize(width: CGFloat(model.original.width) / model.scale, height: CGFloat(model.original.height) / model.scale)
        let fit = min(280 / max(s.width, 1), 148 / max(s.height, 1), 1)
        return CGSize(width: max(s.width * fit, 120), height: max(s.height * fit, 60))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: model.thumbnail)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .frame(maxWidth: .infinity)
                    .padding(10)
                    .background(Checkerboard().opacity(0.35))
                    .onDrag {
                        if let url = model.dragURL { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                        return NSItemProvider(object: model.thumbnail)
                    }
                    .onTapGesture(count: 2) {
                        if let url = model.dragURL { NSWorkspace.shared.open(url) }
                    }
                    .help("拖到其他应用，或双击用“预览”打开")

                Button(action: model.onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(hovering ? 1 : 0)
            }

            Divider().opacity(0.5)

            HStack(spacing: 2) {
                Label(model.status, systemImage: "checkmark.circle.fill")
                    .labelStyle(StatusLabelStyle())
                    .lineLimit(1)
                Spacer(minLength: 6)
                if model.videoURL != nil {
                    PreviewButton(symbol: "doc.on.doc", help: "复制文件") {
                        if let url = model.savedURL { ImageOutput.copyFile(url) }
                        model.status = "已复制文件"
                    }
                    PreviewButton(symbol: model.isExporting ? "hourglass" : "photo.stack", help: "转成 GIF") {
                        model.exportGIF()
                    }
                    .disabled(model.isExporting)
                    PreviewButton(symbol: "play.rectangle", help: "播放") {
                        if let url = model.videoURL { NSWorkspace.shared.open(url) }
                    }
                    PreviewButton(symbol: "folder", help: "在访达中显示") {
                        if let url = model.savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                } else {
                    PreviewButton(symbol: "doc.on.doc", help: "复制") {
                        ImageOutput.copy(model.image, scale: model.scale)
                        model.status = "已复制"
                    }
                    PreviewButton(symbol: model.isBeautified ? "photo" : "sparkles",
                                  help: model.isBeautified ? "恢复原图" : "美化：加背景和阴影") {
                        model.toggleBeautify()
                    }
                    if let url = model.savedURL {
                        PreviewButton(symbol: "folder", help: "在访达中显示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    } else {
                        PreviewButton(symbol: "square.and.arrow.down", help: "保存") {
                            do {
                                model.savedURL = try ImageOutput.save(model.image)
                                model.status = "已保存"
                            } catch { Feedback.error(error) }
                        }
                    }
                    PreviewButton(symbol: "pin", help: "贴到屏幕") {
                        PinWindow.pin(model.image, scale: model.scale)
                        model.onClose()
                    }
                    PreviewButton(symbol: "text.viewfinder", help: "识别文字") {
                        AppController.shared.recognize(image: model.image, scale: model.scale)
                        model.onClose()
                    }
                    PreviewButton(symbol: "translate", help: "翻译") {
                        AppController.shared.translate(image: model.image)
                        model.onClose()
                    }
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: 34)
        }
        .frame(width: 300)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
        .padding(18)
        .onHover { hovering = $0; onHover($0) }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: model.status)
    }
}

private struct StatusLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(.green)
            configuration.title
        }
        .font(.system(size: 12, weight: .medium))
    }
}

private struct PreviewButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.1) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Subtle transparency checkerboard behind thumbnails.
struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 8
            for row in 0..<Int(ceil(size.height / s)) {
                for col in 0..<Int(ceil(size.width / s)) where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                             with: .color(.primary.opacity(0.06)))
                }
            }
        }
    }
}
