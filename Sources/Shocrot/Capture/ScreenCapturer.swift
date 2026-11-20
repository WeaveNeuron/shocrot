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
    var id: CGWindowID = 0
    var pid: pid_t = 0
}

enum CaptureError: LocalizedError {
    case permissionDenied
    case noDisplay
    case windowGone

    var errorDescription: String? {
        switch self {
        case .windowGone: return L("error.windowGone")
        case .permissionDenied: return L("error.permissionDenied")
        case .noDisplay: return L("error.noDisplay")
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

    /// Captures every connected display at native resolution.
    static func captureAllScreens() async throws -> [ScreenSnapshot] {
        try await capture(NSScreen.screens)
    }

    static func capture(_ screens: [NSScreen]) async throws -> [ScreenSnapshot] {
        #if DEBUG
        if let demo = demoSnapshots() { return demo }
        #endif
        guard hasPermission else { throw CaptureError.permissionDenied }
        // Capturing a screen rectangle skips the shareable-content query, which roughly halves the
        // time from hotkey to overlay. Displays are captured in parallel.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let images = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (i, screen) in screens.enumerated() {
                let f = screen.frame
                let rect = CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
                group.addTask { (i, try await SCScreenshotManager.captureImage(in: rect)) }
            }
            var images: [Int: CGImage] = [:]
            for try await (i, image) in group { images[i] = image }
            return images
        }
        let result = screens.indices.compactMap { i in images[i].map { ScreenSnapshot(screen: screens[i], image: $0) } }
        if result.isEmpty { throw CaptureError.noDisplay }
        return result
    }

    /// One window on its own: what is behind or in front of it is left out and the background stays transparent.
    /// Captured 1:1 without the system shadow (which ScreenCaptureKit fits in by shrinking the window), then given
    /// a shadow of our own. Returns the image and its pixels-per-point scale.
    static func captureWindow(_ id: CGWindowID) async throws -> (CGImage, CGFloat) {
        guard hasPermission else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        config.width = Int((filter.contentRect.width * scale).rounded())
        config.height = Int((filter.contentRect.height * scale).rounded())
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (ImageOutput.addingWindowShadow(image, scale: scale) ?? image, scale)
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

    /// On-screen windows, front to back, in AppKit global coordinates. Safe to call off the main thread;
    /// the first call of a session takes ~45 ms, so it runs alongside the screen capture.
    /// `screens` are the display frames in CG coordinates (top-left origin), read on the main thread.
    static func visibleWindows(primaryHeight: CGFloat, screens: [CGRect]) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return windows(from: list, primaryHeight: primaryHeight, ownPID: ProcessInfo.processInfo.processIdentifier,
                       screens: screens,
                       isRegularApp: { NSRunningApplication(processIdentifier: $0)?.activationPolicy == .regular })
    }

    static func windows(from list: [[String: Any]], primaryHeight: CGFloat, ownPID: Int32, screens: [CGRect] = [],
                        isRegularApp: (pid_t) -> Bool = { _ in true }) -> [WindowInfo] {
        list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer < 1000,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" || owner == "Dock" && layer != 0 { return nil }
            // A background utility covering a whole display is an overlay (cursor highlighters, automation
            // tools); snapping to it would hide every window underneath.
            if screens.contains(where: { bounds.insetBy(dx: -2, dy: -2).contains($0) }), !isRegularApp(pid) { return nil }
            // CG uses a top-left origin relative to the primary display; flip to AppKit.
            let flipped = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            return WindowInfo(frame: flipped, title: info[kCGWindowName as String] as? String ?? owner,
                              id: CGWindowID(info[kCGWindowNumber as String] as? Int ?? 0), pid: pid)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
