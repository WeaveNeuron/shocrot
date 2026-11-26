import CoreGraphics
import Testing
@testable import Shocrot

/// Where a newly shown translation panel goes (`TranslatePanel.placement`). AppKit global coordinates.
@MainActor
struct TranslatePanelPlacementTests {
    // A 1920×1080 display with a 30 pt menu bar and a 70 pt Dock.
    let visible = CGRect(x: 0, y: 70, width: 1920, height: 980)
    let planned = TranslatePanel.plannedHeight

    /// The bug: the size came from the panel's current frame, so a tall panel left from a long translation
    /// was placed as if the next one would be as tall. Nothing about the current height goes in any more.
    @Test func plansWithThePlannedHeightNotThePreviousOne() {
        let anchor = CGRect(x: 300, y: 300, width: 400, height: 100)  // room below: 300-12-78 = 210 < 420
        let p = TranslatePanel.placement(width: 420, near: anchor, in: visible)
        // Above, as a 420 pt panel would be: the same as WindowPlacement's own answer for that size.
        #expect(p.topLeft == WindowPlacement.topLeft(for: CGSize(width: 420, height: planned), beside: anchor, in: visible))
    }

    @Test func belowTheSelectionPlacesByTheTopEdge() {
        let anchor = CGRect(x: 300, y: 700, width: 400, height: 100)
        let p = TranslatePanel.placement(width: 420, near: anchor, in: visible)
        #expect(p.topLeft == CGPoint(x: 300, y: 688))
        #expect(p.keptBottom == nil)
    }

    /// Placed above, the panel keeps its bottom 12 pt over the selection whatever height its content ends up,
    /// so a short result no longer floats far above it.
    @Test func aboveTheSelectionKeepsTheBottomByTheSelection() {
        let anchor = CGRect(x: 300, y: 200, width: 400, height: 100)
        let p = TranslatePanel.placement(width: 420, near: anchor, in: visible)
        #expect(p.keptBottom == anchor.maxY + 12)
        #expect(p.topLeft.y == anchor.maxY + 12 + planned)
    }

    @Test func besideOrCentredDoesNotKeepTheBottom() {
        // A selection filling the display height: the panel goes to its right.
        let tall = CGRect(x: 100, y: 80, width: 600, height: 960)
        #expect(TranslatePanel.placement(width: 420, near: tall, in: visible).keptBottom == nil)
        // No anchor: centred.
        let c = TranslatePanel.placement(width: 420, near: nil, in: visible)
        #expect(c.keptBottom == nil)
        #expect(c.topLeft.x == visible.midX - 210)
    }

    @Test func aShortDisplayCapsThePlannedHeight() {
        let small = CGRect(x: 0, y: 0, width: 1024, height: 400)
        let anchor = CGRect(x: 100, y: 100, width: 200, height: 50)
        let p = TranslatePanel.placement(width: 420, near: anchor, in: small)
        // 384 pt tall at most; it can't sit above or below, so it goes beside the selection, inside the display.
        let f = CGRect(x: p.topLeft.x, y: p.topLeft.y - WindowPlacement.maxHeight(in: small), width: 420,
                       height: WindowPlacement.maxHeight(in: small))
        #expect(small.insetBy(dx: WindowPlacement.margin, dy: WindowPlacement.margin).contains(f))
    }

    @Test func placementReportsTheSideItChose() {
        let size = CGSize(width: 420, height: 420)
        func side(_ a: CGRect) -> WindowPlacement.Side { WindowPlacement.placement(for: size, beside: a, in: visible).side }
        #expect(side(CGRect(x: 300, y: 700, width: 100, height: 100)) == .below)
        #expect(side(CGRect(x: 300, y: 100, width: 100, height: 100)) == .above)
        #expect(side(CGRect(x: 100, y: 80, width: 600, height: 960)) == .right)
        #expect(side(CGRect(x: 1300, y: 80, width: 600, height: 960)) == .left)
        #expect(side(CGRect(x: 0, y: 70, width: 1920, height: 980)) == .centred)
    }
}

/// Live QA (build 118): after a 742 pt translation, a selection with room for 420 pt below got a panel pushed up
/// over it, because the window was still 742 pt tall when it was pulled on screen. The planned frame, which the
/// window now takes, fits the display wherever it goes, so pulling it on screen moves nothing.
@MainActor
struct TranslatePanelPlannedFrameTests {
    let visible = CGRect(x: 0, y: 90, width: 1920, height: 960)  // menu bar 30, Dock 90
    let displays: [WindowPlacement.Display] = [(CGRect(x: 0, y: 0, width: 1920, height: 1080),
                                                CGRect(x: 0, y: 90, width: 1920, height: 960))]

    @Test func theReportedSelectionGetsThePanelBelowIt() {
        // Screen y 440…500 (top-left origin) on a 1080 pt display, at the left edge.
        let anchor = CGRect(x: 6, y: 580, width: 214, height: 60)
        let p = TranslatePanel.placement(width: 420, near: anchor, in: visible)
        #expect(p.frame.maxY == anchor.minY - 12)
        #expect(p.frame.minX == WindowPlacement.margin)
        #expect(p.frame.height == TranslatePanel.plannedHeight)
        #expect(!p.frame.intersects(anchor))
        #expect(WindowPlacement.onScreen(p.frame, screens: displays, fallback: nil) == p.frame)
    }

    @Test func thePlannedFrameAlwaysFitsSoThePullBackMovesNothing() {
        let anchors = [CGRect(x: 6, y: 580, width: 214, height: 60), CGRect(x: 1700, y: 1030, width: 200, height: 20),
                       CGRect(x: 1250, y: 120, width: 210, height: 30), CGRect(x: 0, y: 90, width: 1920, height: 960),
                       CGRect(x: 900, y: 500, width: 0, height: 0)]
        for anchor in anchors + [CGRect.null] {
            let p = TranslatePanel.placement(width: 420, near: anchor.isNull ? nil : anchor, in: visible)
            #expect(WindowPlacement.onScreen(p.frame, screens: displays, fallback: nil) == p.frame, "\(anchor)")
            #expect(p.frame.origin.x == p.topLeft.x && p.frame.maxY == p.topLeft.y)
            if let bottom = p.keptBottom { #expect(p.frame.minY == bottom) }
        }
    }
}
