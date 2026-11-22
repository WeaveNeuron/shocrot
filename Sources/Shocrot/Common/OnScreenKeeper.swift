import AppKit

/// Keeps a window inside the visible frame of the display it is on (menu bar and Dock excluded): after its
/// content resizes it, once a drag that moved it ends, and when the displays change (one unplugged, a new
/// resolution, the Dock resized or moved). Nothing moves while the mouse button is down, so the
/// window never fights the user's drag or live resize; it settles as soon as the button is released.
@MainActor
final class OnScreenKeeper {
    private weak var window: NSWindow?
    private let canShrink: Bool
    private let fallback: () -> CGRect?
    private let screens: () -> [WindowPlacement.Display]
    private let isMouseDown: () -> Bool
    private var observers: [NSObjectProtocol] = []
    private var pending: Task<Void, Never>?
    /// Full screen (and its transition) fills the whole display, menu bar area included: leave it alone.
    private var inFullScreen = false

    /// `canShrink`: a window larger than the display is cut down to it (resizable windows); otherwise its top
    /// left stays in view. `fallback`: the visible frame to use while the window is on no display.
    /// `screens` and `isMouseDown` read the live displays and left mouse button unless given.
    init(window: NSWindow, canShrink: Bool = false,
         fallback: @escaping () -> CGRect? = { WindowPlacement.mouseScreen?.visibleFrame },
         screens: @escaping () -> [WindowPlacement.Display] = { WindowPlacement.displays },
         isMouseDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        self.window = window
        self.canShrink = canShrink
        self.fallback = fallback
        self.screens = screens
        self.isMouseDown = isMouseDown
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.keep() }
            })
        }
        // Posted by NSApp; the window itself may not move, e.g. when the Dock grows over it.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keep() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willEnterFullScreenNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.inFullScreen = true }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didExitFullScreenNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.inFullScreen = false
                self?.keep()
            }
        })
    }

    isolated deinit {
        pending?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Pulls the window back now, or right after the mouse button is released if it is down (a drag or live
    /// resize in progress).
    func keep() {
        pending?.cancel()
        pending = nil
        guard isMouseDown() else { pullBack(); return }
        let isMouseDown = isMouseDown
        pending = Task { @MainActor [weak self] in
            while isMouseDown() {
                try? await Task.sleep(for: .milliseconds(80))
                if Task.isCancelled { return }
            }
            self?.pullBack()
        }
    }

    private func pullBack() {
        guard let window, window.isVisible, !window.isMiniaturized, !inFullScreen,
              !window.styleMask.contains(.fullScreen) else { return }
        let fitted = WindowPlacement.onScreen(window.frame, screens: screens(), fallback: fallback(),
                                              canShrink: canShrink)
        guard fitted != window.frame else { return }
        if fitted.size == window.frame.size {
            window.setFrameOrigin(fitted.origin)
        } else {
            window.setFrame(fitted, display: true)
        }
    }
}
