import CoreGraphics
import Testing
@testable import Shocrot

/// Placement on the display arrangements and edges the main suite does not cover: displays at negative
/// coordinates, stacked displays, a menu bar on a second display, small displays, side Docks. AppKit global
/// coordinates (y up, origin at the bottom left of the primary display).
struct WindowPlacementEdgeTests {
    let m = WindowPlacement.margin
    let panel = CGSize(width: 420, height: 420)

    private func frame(_ topLeft: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    private func inside(_ f: CGRect, _ visible: CGRect) -> Bool {
        visible.insetBy(dx: m, dy: m).contains(f)
    }

    // A 1512×982 primary laptop; a 1920×1080 display to its left and slightly below (negative x and y); a
    // 2560×1440 display above it. Each secondary display has its own 25 pt menu bar.
    let laptop: WindowPlacement.Display = (CGRect(x: 0, y: 0, width: 1512, height: 982),
                                           CGRect(x: 0, y: 0, width: 1512, height: 949))
    let left: WindowPlacement.Display = (CGRect(x: -1920, y: -300, width: 1920, height: 1080),
                                         CGRect(x: -1920, y: -300, width: 1920, height: 1055))
    let above: WindowPlacement.Display = (CGRect(x: -500, y: 982, width: 2560, height: 1440),
                                          CGRect(x: -500, y: 982, width: 2560, height: 1415))
    var displays: [WindowPlacement.Display] { [laptop, left, above] }

    @Test func theDisplayIsFoundAtNegativeCoordinates() {
        let frames = displays.map(\.frame)
        #expect(WindowPlacement.index(for: CGRect(x: -1500, y: -200, width: 300, height: 200), among: frames) == 1)
        #expect(WindowPlacement.index(for: CGRect(x: -1, y: -299, width: 0, height: 0), among: frames) == 1)
    }

    @Test func aPointOnTheEdgeBetweenStackedDisplaysFindsOne() {
        let frames = displays.map(\.frame)
        let i = WindowPlacement.index(for: CGRect(x: 700, y: 982, width: 0, height: 0), among: frames)
        #expect(i == 0 || i == 2)
        // A selection straddling the two goes to the one showing most of it.
        #expect(WindowPlacement.index(for: CGRect(x: 600, y: 900, width: 300, height: 400), among: frames) == 2)
    }

    @Test func aSelectionOnTheDisplayAtNegativeCoordinatesGetsThePanelThere() {
        let selection = CGRect(x: -1900, y: -290, width: 200, height: 100) // its bottom left corner
        let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: left.visible), panel)
        #expect(inside(f, left.visible))
        #expect(f.minY >= selection.maxY) // no room below, so above it
    }

    @Test func aPanelUnderASecondDisplaysMenuBarIsPulledDown() {
        let underMenuBar = CGRect(x: 100, y: above.frame.maxY - 300, width: 420, height: 310)
        let f = WindowPlacement.onScreen(underMenuBar, screens: displays, fallback: nil)
        #expect(inside(f, above.visible))
        #expect(f.maxY == above.visible.maxY - m)
    }

    @Test func aPanelDraggedIntoTheGapBesideStackedDisplaysGoesToTheNearestOverlap() {
        // Past the laptop's right edge, below the display above: mostly on the laptop.
        let dragged = CGRect(x: 1300, y: 700, width: 420, height: 400)
        let f = WindowPlacement.onScreen(dragged, screens: displays, fallback: nil)
        #expect(inside(f, laptop.visible))
    }

    /// Every anchor position on every display, selection or point: the panel lands fully inside that display's
    /// visible frame.
    @Test func everyAnchorPutsThePanelInsideItsDisplay() {
        let sizes = [CGSize(width: 0, height: 0), CGSize(width: 80, height: 40), CGSize(width: 600, height: 300),
                     CGSize(width: 1200, height: 900)]
        for display in displays {
            let v = display.visible
            for x in stride(from: v.minX, through: v.maxX, by: v.width / 12) {
                for y in stride(from: v.minY, through: v.maxY, by: v.height / 12) {
                    for s in sizes {
                        let anchor = CGRect(x: x, y: y, width: s.width, height: s.height).intersection(display.frame)
                        let f = frame(WindowPlacement.topLeft(for: panel, beside: anchor, in: v), panel)
                        #expect(inside(f, v), "anchor \(anchor) on \(display.frame)")
                    }
                }
            }
        }
    }

    @Test func aSelectionNearTheRightEdgeGetsThePanelToItsLeft() {
        let visible = laptop.visible
        let selection = CGRect(x: 1200, y: 40, width: 300, height: 880) // tall, against the right edge
        let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: visible), panel)
        #expect(inside(f, visible))
        #expect(f.maxX <= selection.minX)
        #expect(f.maxY == selection.maxY)
    }

    @Test func withoutAnAnchorThePanelIsCentredInTheUpperPart() {
        let visible = laptop.visible
        let f = frame(WindowPlacement.centeredTopLeft(for: panel, in: visible), panel)
        #expect(inside(f, visible))
        #expect(abs(f.midX - visible.midX) < 1)
        #expect(f.midY > visible.midY)
    }

    /// 1024×768 with a 25 pt menu bar and a 60 pt Dock: the planned 420 pt panel still fits, beside any selection.
    @Test func aSmallDisplayStillFitsThePanel() {
        let visible = CGRect(x: 0, y: 60, width: 1024, height: 683)
        for selection in [CGRect(x: 0, y: 60, width: 1024, height: 683), CGRect(x: 300, y: 300, width: 400, height: 200),
                          CGRect(x: 10, y: 70, width: 20, height: 20)] {
            let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: visible), panel)
            #expect(inside(f, visible), "selection \(selection)")
        }
    }

    /// A panel taller than the display: its top (the header, the drag handle) stays reachable.
    @Test func aPanelTallerThanTheDisplayKeepsItsHeaderOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1024, height: 500)
        let tall = CGSize(width: 420, height: 700)
        let placed = WindowPlacement.topLeft(for: tall, beside: CGRect(x: 100, y: 100, width: 50, height: 50),
                                             in: visible)
        #expect(placed.y == visible.maxY - m)
        let centred = WindowPlacement.centeredTopLeft(for: tall, in: visible)
        #expect(centred.y == visible.maxY - m)
    }

    @Test func theTallestPanelLeavesTheMarginAboveAndBelow() {
        #expect(WindowPlacement.maxHeight(in: laptop.visible) == laptop.visible.height - 2 * m)
        #expect(WindowPlacement.maxHeight(in: CGRect(x: 0, y: 0, width: 100, height: 10)) == 0)
    }

    @Test func onScreenWithNoDisplayAndNoFallbackLeavesTheFrame() {
        let f = CGRect(x: -5000, y: -5000, width: 420, height: 400)
        #expect(WindowPlacement.onScreen(f, screens: [], fallback: nil) == f)
    }
}
