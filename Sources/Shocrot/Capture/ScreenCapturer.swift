import AppKit
import ScreenCaptureKit

/// A frozen snapshot of one display, used as the backdrop of the selection overlay.
struct ScreenSnapshot {
    let screen: NSScreen
    let image: CGImage // native pixel resolution
}

/// A window rectangle in AppKit global coordinates (bottom-left origin) used for snapping.
struct WindowInfo {
    let frame: CGRect
    let title: String
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Shocrot 需要“屏幕录制”权限才能截图。"
        case .noDisplay: return "没有找到可截取的显示器。"
        }
    }
}

enum ScreenCapturer {
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    static var canCapture: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["SHOCROT_DEMO_IMAGE"] != nil { return true }
        #endif
        return hasPermission
    }

    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openPermissionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }

    /// Captures every connected display at native resolution.
    static func captureAllScreens() async throws -> [ScreenSnapshot] {
        #if DEBUG
        if let demo = demoSnapshots() { return demo }
        #endif
        guard hasPermission else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var result: [ScreenSnapshot] = []
        for screen in NSScreen.screens {
            guard let id = screen.displayID,
                  let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = false
            config.captureResolution = .best
            config.colorSpaceName = CGColorSpace.sRGB
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(ScreenSnapshot(screen: screen, image: image))
        }
        if result.isEmpty { throw CaptureError.noDisplay }
        return result
    }

    #if DEBUG
    /// Debug builds only: SHOCROT_DEMO_IMAGE=<png> fakes the screen with that image, so the overlay
    /// can be exercised without Screen Recording permission.
    static func demoSnapshots() -> [ScreenSnapshot]? {
        guard let path = ProcessInfo.processInfo.environment["SHOCROT_DEMO_IMAGE"],
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let screen = NSScreen.main else { return nil }
        let w = Int(screen.frame.width * screen.backingScaleFactor), h = Int(screen.frame.height * screen.backingScaleFactor)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 0.45, green: 0.55, blue: 0.7, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: (w - image.width) / 2, y: (h - image.height) / 2, width: image.width, height: image.height))
        return ctx.makeImage().map { [ScreenSnapshot(screen: screen, image: $0)] }
    }
    #endif

    /// On-screen windows, front to back, in AppKit global coordinates.
    static func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer < 1000,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" && layer != 0 { return nil }
            // CG uses a top-left origin relative to the primary display; flip to AppKit.
            let flipped = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowInfo(frame: flipped, title: info[kCGWindowName as String] as? String ?? owner)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
