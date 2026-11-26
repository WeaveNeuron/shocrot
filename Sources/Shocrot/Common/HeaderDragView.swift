import AppKit
import SwiftUI

/// Something a header drag can tell that the user has moved it.
@MainActor
protocol HeaderDraggable: AnyObject {
    func headerDragDidBegin()
}

/// Lets a borderless window be dragged by a header, placed behind it with `.background { HeaderDragHandle() }`.
///
/// It moves the window itself rather than handing the drag to the system (`WindowDragGesture`,
/// `performDrag`): a system drag that ends in the menu bar triggers macOS window tiling ("drag to the menu bar
/// to fill the screen"), which centres a fixed-size panel. The top of the window stays below the menu bar of
/// the display under the pointer while dragging (`WindowPlacement.draggedOrigin`); other edges are left to the
/// window's `OnScreenKeeper` once the mouse button is up.
struct HeaderDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> HeaderDragNSView { HeaderDragNSView() }
    func updateNSView(_ view: HeaderDragNSView, context: Context) {}
}

final class HeaderDragNSView: NSView {
    private var start: (origin: CGPoint, mouse: CGPoint)?

    /// The first click on an inactive panel starts the drag right away.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The window must not move by itself: that would be a system drag again.
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        start = (window.frame.origin, NSEvent.mouseLocation)
        (window as? HeaderDraggable)?.headerDragDidBegin()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let start else { return }
        let origin = WindowPlacement.draggedOrigin(start: start.origin, mouseDown: start.mouse,
                                                   mouse: NSEvent.mouseLocation, size: window.frame.size,
                                                   displays: WindowPlacement.displays)
        if origin != window.frame.origin { window.setFrameOrigin(origin) }
    }

    override func mouseUp(with event: NSEvent) {
        start = nil
    }
}
