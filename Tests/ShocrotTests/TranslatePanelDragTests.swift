import CoreGraphics
import Testing
@testable import Shocrot

/// Dragging the translation panel by its header (`WindowPlacement.draggedOrigin`). AppKit global coordinates:
/// y up, origin at the bottom left of the primary display.
struct TranslatePanelDragTests {
    let m = WindowPlacement.margin
    let size = CGSize(width: 420, height: 300)

    // A 1920×1080 primary display with a 30 pt menu bar and a 70 pt Dock at the bottom.
    let main: WindowPlacement.Display = (CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                         CGRect(x: 0, y: 70, width: 1920, height: 980))
    // A display above the primary one, with its own 25 pt menu bar.
    let upper: WindowPlacement.Display = (CGRect(x: -200, y: 1080, width: 2560, height: 1440),
                                          CGRect(x: -200, y: 1080, width: 2560, height: 1415))
    // A laptop display to the right with a notch: its menu bar is 38 pt.
    let notched: WindowPlacement.Display = (CGRect(x: 1920, y: 0, width: 1512, height: 982),
                                            CGRect(x: 1920, y: 0, width: 1512, height: 944))

    private func drag(from start: CGPoint, by delta: CGVector, on displays: [WindowPlacement.Display]) -> CGPoint {
        let down = CGPoint(x: start.x + 200, y: start.y + size.height - 10)  // a point in the header
        let mouse = CGPoint(x: down.x + delta.dx, y: down.y + delta.dy)
        return WindowPlacement.draggedOrigin(start: start, mouseDown: down, mouse: mouse, size: size,
                                             displays: displays)
    }

    @Test func aDragInTheMiddleFollowsThePointer() {
        let o = drag(from: CGPoint(x: 600, y: 300), by: CGVector(dx: -150, dy: 120), on: [main])
        #expect(o == CGPoint(x: 450, y: 420))
    }

    /// The reported bug: dropped in the menu bar, the panel jumped to the centre. It now keeps its x and its
    /// top stops below the menu bar.
    @Test func dragIntoTheMenuBarKeepsXAndStopsBelowIt() {
        let start = CGPoint(x: 1440, y: 538)  // top at 838
        let o = drag(from: start, by: CGVector(dx: 30, dy: 240), on: [main])  // pointer at y 1068, in the menu bar
        #expect(o.x == 1470)
        #expect(o.y + size.height == main.visible.maxY - m)
        // Pointer right inside the menu bar (y 1060), not past the display.
        let down = CGPoint(x: 1640, y: 828)
        let o2 = WindowPlacement.draggedOrigin(start: start, mouseDown: down, mouse: CGPoint(x: 1640, y: 1060),
                                               size: size, displays: [main])
        #expect(o2 == CGPoint(x: 1440, y: main.visible.maxY - m - size.height))
    }

    @Test func leftRightAndBottomAreLeftToTheKeeper() {
        let start = CGPoint(x: 100, y: 300)
        // Past the left edge: x goes negative while the button is down.
        #expect(drag(from: start, by: CGVector(dx: -250, dy: 0), on: [main]).x == -150)
        // Past the right edge.
        #expect(drag(from: CGPoint(x: 1400, y: 300), by: CGVector(dx: 300, dy: 0), on: [main]).x == 1700)
        // Into the Dock.
        #expect(drag(from: start, by: CGVector(dx: 0, dy: -280), on: [main]).y == 20)
    }

    @Test func theMenuBarOfTheDisplayUnderThePointerCounts() {
        // Dragged up onto the display above: the main display's menu bar no longer stops it.
        let o = drag(from: CGPoint(x: 600, y: 600), by: CGVector(dx: 0, dy: 900), on: [main, upper])
        #expect(o.y == 1500)
        // But the upper display's own menu bar does.
        let high = drag(from: CGPoint(x: 600, y: 600), by: CGVector(dx: 0, dy: 1600), on: [main, upper])  // pointer at y 2490
        #expect(high.y + size.height == upper.visible.maxY - m)
        #expect(high.x == 600)
    }

    @Test func aNotchedDisplaysTallerMenuBarCounts() {
        let o = drag(from: CGPoint(x: 2400, y: 500), by: CGVector(dx: 0, dy: 180), on: [main, notched])  // pointer at y 970
        #expect(o.y + size.height == notched.visible.maxY - m)
        #expect(o.x == 2400)
    }

    @Test func aPointerOffEveryDisplayIsNotClamped() {
        let o = drag(from: CGPoint(x: 600, y: 600), by: CGVector(dx: 0, dy: 900), on: [main])
        #expect(o == CGPoint(x: 600, y: 1500))
    }
}
