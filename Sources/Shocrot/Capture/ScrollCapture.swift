import AppKit
import Carbon.HIToolbox
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
    private var keyTap: KeyInterceptor?

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
        // ↩ finishes and Esc cancels while the scrolled app keeps keyboard focus. An event tap (needs
        // Accessibility) swallows just those two keys, so they don't also type into that app. Without the
        // permission the buttons still work.
        keyTap = KeyInterceptor(keyCodes: [kVK_Return, kVK_ANSI_KeypadEnter, kVK_Escape]) { [weak self] code in
            if code == kVK_Escape { self?.cancel() } else { self?.finish() }
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
        keyTap?.stop()
        keyTap = nil
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
                .buttonStyle(HUDProminentButtonStyle(color: .accentColor))
                .help("完成 (↩)")
        }
        .controlSize(.regular)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.6)), in: .capsule)
        .animation(.easeOut(duration: 0.15), value: model.height)
        // The panel never becomes key; without this the buttons draw in their inactive grey.
        .environment(\.controlActiveState, .key)
        .padding(10)
    }
}

/// A filled capsule that keeps its colour in panels that never become key (where `.glassProminent` greys out).
struct HUDProminentButtonStyle: ButtonStyle {
    let color: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize()
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(color.opacity(isEnabled ? 1 : 0.4)))
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}

/// Swallows a few keys system-wide for as long as it lives, reporting each press on the main thread.
final class KeyInterceptor {
    private let keyCodes: Set<Int>
    private let onPress: (Int) -> Void
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    init?(keyCodes: Set<Int>, onPress: @escaping (Int) -> Void) {
        self.keyCodes = keyCodes
        self.onPress = onPress
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<KeyInterceptor>.fromOpaque(info).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return nil }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard keyCodes.contains(code), modifiers.isEmpty else { return Unmanaged.passUnretained(event) }
        if type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            DispatchQueue.main.async { self.onPress(code) }
        }
        return nil // swallowed
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    deinit { stop() }
}
