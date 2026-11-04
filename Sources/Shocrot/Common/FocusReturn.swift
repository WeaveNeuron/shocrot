import AppKit

/// The app that had focus before a capture opened one of our windows (the save panel, an OCR window).
/// When the last such window goes away focus goes back to it, instead of staying with Shocrot,
/// which then has nothing on screen to type into.
enum FocusReturn {
    private static var app: NSRunningApplication?

    static func remember(_ app: NSRunningApplication?) {
        self.app = app
    }

    /// Call when one of our windows has closed or is closing.
    static func windowDidGoAway() {
        // Wait for the closing window to leave the screen before counting what is left.
        DispatchQueue.main.async {
            guard let app else { return }
            let titled = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
            guard shouldReturn(appIsActive: NSApp.isActive, hasTitledWindow: titled, targetTerminated: app.isTerminated) else {
                if !NSApp.isActive || app.isTerminated { self.app = nil } // the user moved on
                return
            }
            self.app = nil
            app.activate()
        }
    }

    /// Only while Shocrot still has focus: if the user switched apps meanwhile, leave it where they put it.
    static func shouldReturn(appIsActive: Bool, hasTitledWindow: Bool, targetTerminated: Bool) -> Bool {
        appIsActive && !hasTitledWindow && !targetTerminated
    }
}
