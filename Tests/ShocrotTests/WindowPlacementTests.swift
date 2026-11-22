import CoreGraphics
import Testing
@testable import Shocrot

/// AppKit global coordinates (y up). A 1512×982 laptop display with a 33 pt menu bar and a hidden Dock, and a
/// 1920×1050 display to its right, raised by 74 pt (the arrangement seen on the machine this was fixed on).
struct WindowPlacementTests {
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let laptopVisible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let external = CGRect(x: 1512, y: 74, width: 1920, height: 1050)
    let panel = CGSize(width: 420, height: 420)
    let m = WindowPlacement.margin

    private func frame(_ topLeft: CGPoint, _ size: CGSize) -> CGRect {
        CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
    }

    private func inside(_ f: CGRect, _ b: CGRect) -> Bool {
        b.insetBy(dx: m, dy: m).contains(f)
    }

    @Test func screenIsTheOneShowingMostOfTheSelection() {
        let frames = [laptop, external]
        #expect(WindowPlacement.index(for: CGRect(x: 1400, y: 300, width: 400, height: 200), among: frames) == 1)
        #expect(WindowPlacement.index(for: CGRect(x: 1300, y: 300, width: 300, height: 200), among: frames) == 0)
        // A point on the shared edge, or at a display's very top, still finds a display.
        #expect(WindowPlacement.index(for: CGRect(x: 1512, y: 500, width: 0, height: 0), among: frames) != nil)
        #expect(WindowPlacement.index(for: CGRect(x: 100, y: 982, width: 0, height: 0), among: frames) == 0)
        #expect(WindowPlacement.index(for: CGRect(x: -500, y: -500, width: 0, height: 0), among: frames) == nil)
    }

    /// The reported bug: a selection reaching the bottom of the display put the panel in the bottom-left corner,
    /// partly below the screen.
    @Test func selectionNearTheBottomPutsThePanelAboveIt() {
        let selection = CGRect(x: 180, y: 102, width: 1150, height: 320)
        let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: laptopVisible), panel)
        #expect(inside(f, laptopVisible))
        #expect(f.minY >= selection.maxY)
    }

    @Test func selectionNearTheTopPutsThePanelBelowIt() {
        let selection = CGRect(x: 300, y: 700, width: 500, height: 200)
        let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: laptopVisible), panel)
        #expect(inside(f, laptopVisible))
        #expect(f.maxY <= selection.minY)
        #expect(f.minX == selection.minX)
    }

    @Test func tallSelectionPutsThePanelBesideIt() {
        let selection = CGRect(x: 100, y: 50, width: 600, height: 850)
        let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: laptopVisible), panel)
        #expect(inside(f, laptopVisible))
        #expect(f.minX >= selection.maxX)
    }

    @Test func fullScreenSelectionCentresThePanelOnThatDisplay() {
        let visible = CGRect(x: 1512, y: 74, width: 1920, height: 1017)
        let f = frame(WindowPlacement.topLeft(for: panel, beside: external, in: visible), panel)
        #expect(inside(f, visible))
        #expect(abs(f.midX - visible.midX) < 1)
    }

    @Test func selectionOnTheSecondDisplayStaysOnIt() {
        let visible = CGRect(x: 1512, y: 74, width: 1920, height: 1017)
        let selection = CGRect(x: 3300, y: 80, width: 120, height: 60) // bottom-right corner of the external
        let f = frame(WindowPlacement.topLeft(for: panel, beside: selection, in: visible), panel)
        #expect(inside(f, visible))
    }

    @Test func pointAnchorAtTheBottomEdgeStaysVisible() {
        let f = frame(WindowPlacement.topLeft(for: panel, beside: CGRect(x: 1500, y: 2, width: 0, height: 0),
                                              in: laptopVisible), panel)
        #expect(inside(f, laptopVisible))
    }

    @Test func fitPullsAGrownPanelBackOnScreen() {
        // Build 98: top left kept at y = 208 while the content grew to 631 pt.
        let grown = CGRect(x: 180, y: 208 - 631, width: 420, height: 631)
        let f = WindowPlacement.fit(grown, in: laptopVisible)
        #expect(inside(f, laptopVisible))
        #expect(f.size == grown.size)
    }

    @Test func fitKeepsTheTopOfAWindowTallerThanTheDisplay() {
        let tall = CGRect(x: -50, y: -400, width: 420, height: 1200)
        let f = WindowPlacement.fit(tall, in: laptopVisible)
        #expect(f.maxY == laptopVisible.maxY - m)
        #expect(f.minX == m)
    }

    @Test func fitLeavesAFrameThatAlreadyFitsAlone() {
        let ok = CGRect(x: 500, y: 300, width: 420, height: 400)
        #expect(WindowPlacement.fit(ok, in: laptopVisible) == ok)
    }
}
