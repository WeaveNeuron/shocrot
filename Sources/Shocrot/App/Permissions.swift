import AppKit
import SwiftUI

/// The system permissions Shocrot uses, with live status and a guided way to grant them.
enum Permission: String, CaseIterable, Identifiable {
    case screenRecording, accessibility

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: "屏幕录制"
        case .accessibility: "辅助功能"
        }
    }

    var detail: String {
        switch self {
        case .screenRecording: "截图、识别文字与截图翻译"
        case .accessibility: "划词翻译读取选中的文字（可选）"
        }
    }

    var symbol: String {
        switch self {
        case .screenRecording: "rectangle.dashed"
        case .accessibility: "character.cursor.ibeam"
        }
    }

    private var paneURL: URL {
        let anchor = self == .screenRecording ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    enum Status { case granted, needsRelaunch, missing }

    var status: Status {
        switch self {
        case .screenRecording:
            if ScreenCapturer.hasPermission { return .granted }
            // The preflight result is cached per process; other apps' window titles become readable
            // as soon as access is granted, so that tells us a relaunch will pick it up.
            return Self.canReadWindowTitles ? .needsRelaunch : .missing
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .missing
        }
    }

    /// Opens the matching System Settings pane with a drag-to-grant helper attached to it.
    @MainActor func request() {
        // macOS only lets the opened app come forward if we hand over activation explicitly.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: "com.apple.systempreferences")
        NSWorkspace.shared.open(paneURL, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            DispatchQueue.main.async { app?.activate(options: .activateAllWindows) }
        }
        PermissionGuide.show(for: self)
    }

    private static var canReadWindowTitles: Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[CFString: Any]] ?? []
        return windows.contains {
            ($0[kCGWindowOwnerPID] as? pid_t) != me && ($0[kCGWindowLayer] as? Int) == 0
                && ($0[kCGWindowName] as? String)?.isEmpty == false
        }
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", Bundle.main.bundlePath]
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { try? task.run(); NSApp.terminate(nil) }
    }
}

/// One permission with its live status and action; used by onboarding and Settings.
struct PermissionRow: View {
    let permission: Permission
    @State private var status: Permission.Status
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(_ permission: Permission) {
        self.permission = permission
        _status = State(initialValue: permission.status)
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: permission.symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(status == .needsRelaunch ? "已开启，重新启动后生效" : permission.detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("已开启", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            case .needsRelaunch:
                Button("重新启动", action: Permission.relaunch).buttonStyle(.glassProminent)
            case .missing:
                Button("去开启", action: permission.request).buttonStyle(.glass)
            }
        }
        .onReceive(timer) { _ in status = permission.status }
    }
}

/// A floating card pinned to the bottom of System Settings with a draggable app tile,
/// so granting is "drag the icon into the list" instead of hunting for the + button.
@MainActor
enum PermissionGuide {
    private static var panel: NSPanel?
    private static var timer: Timer?
    private static let settingsBundleID = "com.apple.systempreferences"

    static func show(for permission: Permission) {
        close()
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .floating
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let layout = GuideLayout()
        let host = NSHostingView(rootView: PermissionGuideView(permission: permission, layout: layout, onClose: close))
        host.sizingOptions = .intrinsicContentSize
        p.contentView = host
        panel = p

        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                if permission.status != .missing { close(); return }
                let settingsRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).isEmpty
                if !settingsRunning && Date().timeIntervalSince(started) > 5 { close(); return }
                // Follow the System Settings window, and step aside while another app is on top of it.
                if let frame = settingsWindowFrame() {
                    // Line up with the app list, which fills the pane right of the fixed-width sidebar.
                    let list = NSRect(x: frame.minX + 252, y: frame.minY, width: frame.width - 252 - 20, height: frame.height)
                    if layout.width != list.width { layout.width = list.width }
                    host.layoutSubtreeIfNeeded()
                    let size = host.fittingSize
                    p.setFrame(NSRect(x: list.minX - GuideLayout.inset, y: frame.minY + 8,
                                      width: size.width, height: size.height), display: true)
                    panel?.orderFrontRegardless()
                } else {
                    panel?.orderOut(nil)
                }
            }
        }
    }

    static func close() {
        timer?.invalidate()
        timer = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// The System Settings window, if it is the topmost window outside Shocrot, in Cocoa coordinates.
    /// (Window bounds and owners are readable without any permission.)
    private static func settingsWindowFrame() -> NSRect? {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID)
                .first?.processIdentifier,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[CFString: Any]],
              // Skip our own windows and overlays of background utilities (no Dock icon).
              let top = windows.first(where: { w in
                  guard (w[kCGWindowLayer] as? Int) == 0, let owner = w[kCGWindowOwnerPID] as? pid_t, owner != me
                  else { return false }
                  return NSRunningApplication(processIdentifier: owner)?.activationPolicy == .regular
              }),
              (top[kCGWindowOwnerPID] as? pid_t) == pid,
              let dict = top[kCGWindowBounds], let rect = CGRect(dictionaryRepresentation: dict as! CFDictionary),
              rect.width > 200
        else { return nil }
        let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: screenTop - rect.maxY, width: rect.width, height: rect.height)
    }
}

@MainActor
private final class GuideLayout: ObservableObject {
    static let inset: CGFloat = 12 // transparent margin around the card for its shadow
    @Published var width: CGFloat = 380
}

private struct PermissionGuideView: View {
    let permission: Permission
    @ObservedObject var layout: GuideLayout
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor.gradient)
                    .symbolEffect(.bounce.up, options: .repeat(.periodic(delay: 1.2)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("开启“\(permission.title)”").font(.system(size: 14, weight: .semibold))
                    Text("拖进上方列表，或打开它的开关")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .glassEffect(.regular.interactive(), in: .circle)
                .help("关闭指引")
            }

            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                Text("Shocrot").font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: "hand.draw")
                    .font(.system(size: 13)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(.background.opacity(hovering ? 0.75 : 0.55))
                    .shadow(color: .black.opacity(hovering ? 0.22 : 0.12), radius: hovering ? 8 : 4, y: hovering ? 4 : 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12))
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.snappy(duration: 0.2), value: hovering)
            .onHover { hovering = $0; (hovering ? NSCursor.openHand : NSCursor.arrow).set() }
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onDrag { NSItemProvider(object: Bundle.main.bundleURL as NSURL) }

            Label("已在列表中却不生效？选中它点「−」移除，再拖进来", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(width: layout.width)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
        .padding(GuideLayout.inset)
    }
}
