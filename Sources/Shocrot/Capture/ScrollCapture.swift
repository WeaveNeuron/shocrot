import AppKit
import ScreenCaptureKit
import SwiftUI

/// Scrolling capture: keeps grabbing a screen region while the user scrolls the content under it,
/// and stitches the frames into one tall image.
@MainActor
final class ScrollCapture {
    private static var current: ScrollCapture?

    private let rect: CGRect      // AppKit global points
    private let screen: NSScreen
    private let completion: (CGImage, CGFloat) -> Void
    private let model = ScrollCaptureModel()
    private var stitcher = ScrollStitcher()
    private var border: NSPanel?
    private var hud: NSPanel?
    private var loop: Task<Void, Never>?
    private var keyMonitors: [Any] = []

    static var isActive: Bool { current != nil }

    static func start(rect: CGRect, on screen: NSScreen, completion: @escaping (CGImage, CGFloat) -> Void) {
        guard current == nil else { return }
        let session = ScrollCapture(rect: rect.integral, screen: screen, completion: completion)
        current = session
        session.begin()
    }

    private init(rect: CGRect, screen: NSScreen, completion: @escaping (CGImage, CGFloat) -> Void) {
        self.rect = rect
        self.screen = screen
        self.completion = completion
    }

    private var scale: CGFloat { screen.backingScaleFactor }

    private func begin() {
        showBorder()
        showHUD()
        // Return finishes and Esc cancels even while the scrolled app keeps keyboard focus.
        let handler: (NSEvent) -> Void = { [weak self] event in
            switch event.keyCode {
            case 36, 76: self?.finish()
            case 53: self?.cancel()
            default: break
            }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { keyMonitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) {
            keyMonitors.append(m)
        }
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        do {
            // Let the selection overlay leave the screen before the first frame.
            try await Task.sleep(for: .milliseconds(250))
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else {
                throw CaptureError.noDisplay
            }
            let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            let config = SCStreamConfiguration()
            // sourceRect is in display points with a top-left origin.
            config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                       width: rect.width, height: rect.height)
            config.width = Int(rect.width * scale)
            config.height = Int(rect.height * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB

            while !Task.isCancelled {
                let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                if Task.isCancelled { break }
                apply(stitcher.add(frame))
                if model.isFull { finish(); return }
                try await Task.sleep(for: .milliseconds(90))
            }
        } catch is CancellationError {
        } catch {
            close()
            Feedback.error(error)
        }
    }

    private func apply(_ update: ScrollStitcher.Update) {
        model.height = Int(CGFloat(stitcher.height) / scale)
        switch update {
        case .started, .unchanged: break
        case .appended: model.warning = nil
        case .lost: model.warning = "滚动慢一点，或向下滚动"
        case .full: model.isFull = true
        }
    }

    func finish() {
        guard Self.current === self else { return }
        let image = stitcher.makeImage()
        close()
        if let image { completion(image, scale) }
    }

    func cancel() { close() }

    private func close() {
        loop?.cancel()
        keyMonitors.forEach(NSEvent.removeMonitor)
        keyMonitors.removeAll()
        border?.orderOut(nil)
        hud?.orderOut(nil)
        border = nil
        hud = nil
        if Self.current === self { Self.current = nil }
    }

    // MARK: Windows

    private func showBorder() {
        let inset: CGFloat = 3
        let p = NSPanel(contentRect: rect.insetBy(dx: -inset, dy: -inset), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true // scrolling goes straight to the app underneath
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = NSView()
        view.wantsLayer = true
        // A ring just outside the captured area, so it never lands in the image.
        let ring = CAShapeLayer()
        ring.path = CGPath(roundedRect: CGRect(origin: .zero, size: p.frame.size).insetBy(dx: 1, dy: 1),
                           cornerWidth: 4, cornerHeight: 4, transform: nil)
        ring.fillColor = nil
        ring.strokeColor = NSColor.controlAccentColor.cgColor
        ring.lineWidth = 2
        ring.lineDashPattern = [6, 4]
        view.layer?.addSublayer(ring)
        p.contentView = view
        p.orderFrontRegardless()
        border = p
    }

    private func showHUD() {
        let host = NSHostingView(rootView: ScrollCaptureHUD(model: model, onCancel: { [weak self] in self?.cancel() },
                                                            onDone: { [weak self] in self?.finish() }))
        let size = host.fittingSize
        let vf = screen.visibleFrame
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 10)
        if origin.y < vf.minY + 4 { origin.y = rect.maxY + 10 }                     // no room below: go above
        if origin.y + size.height > vf.maxY - 4 { origin.y = rect.minY + 12 }       // nor above: float inside
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        let p = NSPanel(contentRect: CGRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        p.orderFrontRegardless()
        hud = p
    }
}

@MainActor
final class ScrollCaptureModel: ObservableObject {
    @Published var height = 0
    @Published var warning: String?
    @Published var isFull = false
}

private struct ScrollCaptureHUD: View {
    @ObservedObject var model: ScrollCaptureModel
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: model.warning == nil ? "arrow.down" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.warning == nil ? Color.accentColor : .orange)
                .symbolEffect(.bounce.down, options: .repeat(.periodic(delay: 1)), isActive: model.warning == nil)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.warning ?? "向下滚动页面").font(.system(size: 13, weight: .semibold))
                Text(model.height > 0 ? "已拼接 \(model.height) pt 高" : "准备中…")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            .frame(width: 150, alignment: .leading)
            Button("取消", action: onCancel)
                .buttonStyle(.glass)
                .help("取消 (Esc)")
            Button("完成", action: onDone)
                .buttonStyle(.glassProminent)
                .help("完成 (↩)")
        }
        .controlSize(.regular)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.6)), in: .capsule)
        .animation(.easeOut(duration: 0.15), value: model.height)
        .padding(10)
    }
}
