import AppKit

/// Reliably brings a titled Shocrot window forward from an `.accessory` (menu-bar) app:
/// unhides the app, deminiaturizes if needed, pulls the window onto the active Space,
/// keeps it inside a connected display's visible frame, and activates Shocrot.
@MainActor
enum WindowPresentation {
    enum ReopenAction: Equatable {
        case showSettings
        case frontExistingTitled
    }

    static func activateApp() {
        if NSApp.isHidden { NSApp.unhide(nil) }
        // Menu-bar (.accessory) apps are often triggered while another regular app is active without an
        // activation handoff (URL scheme, non-activating panel, hotkey, menu dismissal). Combining both calls
        // ensures activation succeeds alongside orderFrontRegardless().
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        NSApp.activate()
    }

    /// Configures collection behavior, deminiaturizes, and ensures a valid on-screen frame without ordering front.
    static func prepare(_ window: NSWindow, centerOnMouseScreenWhenHidden: Bool = false, preferredSize: CGSize? = nil,
                        displays: [WindowPlacement.Display] = WindowPlacement.displays,
                        mouseVisibleFrame: CGRect? = WindowPlacement.mouseScreen?.visibleFrame) {
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }

        if centerOnMouseScreenWhenHidden && !window.isVisible {
            let size = preferredSize ?? window.frame.size
            if let visible = mouseVisibleFrame {
                let target = centeredFrame(size: size, in: visible)
                window.setFrame(target, display: false)
            }
        } else {
            let fitted = WindowPlacement.onScreen(
                window.frame,
                screens: displays,
                fallback: mouseVisibleFrame,
                canShrink: window.styleMask.contains(.resizable)
            )
            if fitted != window.frame {
                window.setFrame(fitted, display: false)
            }
        }
    }

    /// Presents a titled window in front of other apps on the active Space.
    static func present(_ window: NSWindow, centerOnMouseScreenWhenHidden: Bool = false, preferredSize: CGSize? = nil) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        prepare(window, centerOnMouseScreenWhenHidden: centerOnMouseScreenWhenHidden, preferredSize: preferredSize)

        // AppKit does not always migrate an already-visible window to another Space on makeKeyAndOrderFront alone,
        // even with `.moveToActiveSpace`. Ordering it out first makes WindowServer attach it to the current Space.
        if shouldRelocateToActiveSpace(isVisible: window.isVisible, isOnActiveSpace: window.isOnActiveSpace) {
            window.orderOut(nil)
        }

        activateApp()
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        // Re-assert on the next run-loop turn: when triggered from an NSStatusItem menu, AppKit's menu teardown
        // can hand focus back to the prior regular app right after the action fires, burying the window.
        DispatchQueue.main.async { [weak window] in
            guard let window, window.isVisible, !window.isMiniaturized else { return }
            if !NSApp.isActive || !window.isKeyWindow {
                activateApp()
                window.orderFrontRegardless()
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    /// Centers `size` inside `visible` and fits it inside `visible` inset by `margin`.
    nonisolated static func centeredFrame(size: CGSize, in visible: CGRect, margin: CGFloat = WindowPlacement.margin) -> CGRect {
        let origin = CGPoint(x: (visible.midX - size.width / 2).rounded(),
                             y: (visible.midY - size.height / 2).rounded())
        return WindowPlacement.fit(CGRect(origin: origin, size: size), in: visible, margin: margin)
    }

    /// True when the window is currently visible on another Space and must be ordered out before re-presenting.
    nonisolated static func shouldRelocateToActiveSpace(isVisible: Bool, isOnActiveSpace: Bool) -> Bool {
        isVisible && !isOnActiveSpace
    }

    /// What launching Shocrot again from Finder or Spotlight should do. Floating panels (pins, translate panel,
    /// preview card) don't count as a main window, and an already-open Settings window is always brought forward.
    nonisolated static func reopenAction(settingsOpen: Bool, hasVisibleTitledOnActiveSpace: Bool) -> ReopenAction {
        if settingsOpen || !hasVisibleTitledOnActiveSpace { return .showSettings }
        return .frontExistingTitled
    }
}
