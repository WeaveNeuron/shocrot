import CoreGraphics
import Foundation
import Testing
@testable import Shocrot

private struct SelectionStubService: TranslationService {
    let name = "Stub"
    let symbol = "apple.logo"
    let output: String
    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield(output); $0.finish() }
    }
}

@Suite("Selection translation security")
struct SelectionSecurityTests {
    @Test func suppressesSecureTextFieldsAndSecureInput() {
        #expect(SelectionSecurity.isProtected(role: "AXSecureTextField", subrole: nil, roleDescription: nil, isSecureInputEnabled: false))
        #expect(SelectionSecurity.isProtected(role: "AXTextField", subrole: "AXSecureTextField", roleDescription: nil, isSecureInputEnabled: false))
        #expect(SelectionSecurity.isProtected(role: "AXTextField", subrole: nil, roleDescription: "secure text field", isSecureInputEnabled: false))
        #expect(SelectionSecurity.isProtected(role: "AXTextField", subrole: nil, roleDescription: "密码输入框", isSecureInputEnabled: false))
        #expect(SelectionSecurity.isProtected(role: "AXTextArea", subrole: nil, roleDescription: "text area", isSecureInputEnabled: true))
    }

    @Test func allowsRegularTextElementsWhenSecureInputIsOff() {
        #expect(!SelectionSecurity.isProtected(role: "AXTextArea", subrole: nil, roleDescription: "text area", isSecureInputEnabled: false))
        #expect(!SelectionSecurity.isProtected(role: "AXTextField", subrole: "AXSearchField", roleDescription: "search text field", isSecureInputEnabled: false))
        #expect(!SelectionSecurity.isProtected(role: "AXStaticText", subrole: nil, roleDescription: "text", isSecureInputEnabled: false))
        #expect(!SelectionSecurity.isProtected(role: "AXWebArea", subrole: nil, roleDescription: "HTML content", isSecureInputEnabled: false))
    }
}

@Suite("Selection translation layout")
struct SelectionPopupLayoutTests {
    typealias L = SelectionPopupLayout
    let visible = CGRect(x: 0, y: 70, width: 1920, height: 980)

    @Test func convertsCoordinatesBetweenCGAndAppKitAcrossDisplays() {
        let primaryHeight: CGFloat = 1080
        // Primary display point
        let cgRect = CGRect(x: 400, y: 200, width: 180, height: 22)
        let akRect = L.cgRectToAppKit(cgRect, primaryScreenHeight: primaryHeight)
        #expect(akRect == CGRect(x: 400, y: 858, width: 180, height: 22))
        let backPoint = L.appKitPointToCG(CGPoint(x: akRect.minX, y: akRect.maxY), primaryScreenHeight: primaryHeight)
        #expect(backPoint == CGPoint(x: cgRect.minX, y: cgRect.minY))

        // Secondary display positioned above primary (negative CG y -> AppKit y > primaryHeight)
        let upperCG = CGRect(x: 100, y: -300, width: 200, height: 20)
        let upperAK = L.cgRectToAppKit(upperCG, primaryScreenHeight: primaryHeight)
        #expect(upperAK == CGRect(x: 100, y: 1360, width: 200, height: 20))
    }

    @Test func triggersOnlyOnRealDragOrMultiClick() {
        #expect(!L.shouldTrigger(mouseDown: CGPoint(x: 100, y: 100), mouseUp: CGPoint(x: 100, y: 100), clickCount: 1))
        #expect(!L.shouldTrigger(mouseDown: CGPoint(x: 100, y: 100), mouseUp: CGPoint(x: 103, y: 102), clickCount: 1))
        #expect(L.shouldTrigger(mouseDown: CGPoint(x: 100, y: 100), mouseUp: CGPoint(x: 120, y: 100), clickCount: 1))
        #expect(L.shouldTrigger(mouseDown: CGPoint(x: 200, y: 100), mouseUp: CGPoint(x: 120, y: 100), clickCount: 1))
        #expect(L.shouldTrigger(mouseDown: CGPoint(x: 100, y: 100), mouseUp: CGPoint(x: 100, y: 100), clickCount: 2))
        #expect(L.shouldTrigger(mouseDown: CGPoint(x: 100, y: 100), mouseUp: CGPoint(x: 100, y: 100), clickCount: 3))
    }

    @Test func cleanedSelectionFiltersWhitespaceAndBarePunctuation() {
        #expect(L.cleanedSelection(nil) == nil)
        #expect(L.cleanedSelection("   \n\t ") == nil)
        #expect(L.cleanedSelection("...---!!!") == nil)
        #expect(L.cleanedSelection(String(repeating: "a", count: 4001)) == nil)
        #expect(L.cleanedSelection("  Hello world  ") == "Hello world")
        #expect(L.cleanedSelection("  你好世界\n") == "你好世界")
    }

    @Test func trimmedLineRangeStripsNewlinesAndOuterWhitespace() {
        let line = L.trimmedLineRange(CFRange(location: 40, length: 16), text: "  Hello world \n")
        #expect(line?.location == 42)
        #expect(line?.length == 11)

        // Blank / newline-only lines return nil so they don't distort adjacent clearance.
        #expect(L.trimmedLineRange(CFRange(location: 10, length: 3), text: " \t\n") == nil)

        // CJK characters keep exact UTF-16 range alignment.
        let zh = L.trimmedLineRange(CFRange(location: 100, length: 5), text: "简体中文\n")
        #expect(zh?.location == 100 && zh?.length == 4)
    }

    @Test func clearedLineBoundsClearsOverhangingAdjacentLinesAndRespectsContainer() {
        let line = CGRect(x: 490, y: 700, width: 774, height: 16) // maxX = 1264
        let nextLine = CGRect(x: 490, y: 684, width: 790, height: 16) // maxX = 1280, overlaps centered 28pt icon vertically
        let farBelow = CGRect(x: 490, y: 620, width: 900, height: 16) // too far vertically to overlap
        let cleared = L.clearedLineBounds(line, adjacentLines: [nextLine, farBelow])
        #expect(cleared.minX == 490)
        #expect(cleared.maxX == 1280)
        #expect(cleared.minY == 700 && cleared.height == 16)

        // Horizontally scrolled container clips the reported line edge to the visible viewport.
        let viewport = CGRect(x: 480, y: 500, width: 600, height: 400) // maxX = 1080
        let clipped = L.clearedLineBounds(line, adjacentLines: [nextLine], container: viewport)
        #expect(clipped.maxX == 1080)
    }

    /// Left-to-right drag: places icon to the right of the selection's line, vertically centered on that line.
    /// Right-to-left drag: places icon to the left of the selection's line, vertically centered on that line.
    /// Neither overlaps the selected text or the next line underneath.
    @Test func iconSitsBesideLineVerticallyCenteredWithoutCoveringText() {
        let fullLine = CGRect(x: 490, y: 700, width: 770, height: 18) // x 490...1260
        let midSelection = CGRect(x: 660, y: 700, width: 250, height: 18) // mid-line selection
        let nextLine = CGRect(x: 490, y: 680, width: 770, height: 18) // directly below

        let lrIcon = L.iconFrame(mouseDown: CGPoint(x: 660, y: 709),
                                 mouseUp: CGPoint(x: 910, y: 709),
                                 selectionBounds: midSelection,
                                 lineBounds: fullLine,
                                 in: visible)
        #expect(lrIcon.minX == fullLine.maxX + L.iconGap)
        #expect(abs(lrIcon.midY - fullLine.midY) <= 1)
        #expect(!lrIcon.intersects(fullLine))
        #expect(!lrIcon.intersects(nextLine))

        let rlIcon = L.iconFrame(mouseDown: CGPoint(x: 910, y: 709),
                                 mouseUp: CGPoint(x: 660, y: 709),
                                 selectionBounds: midSelection,
                                 lineBounds: fullLine,
                                 in: visible)
        #expect(rlIcon.maxX == fullLine.minX - L.iconGap)
        #expect(abs(rlIcon.midY - fullLine.midY) <= 1)
        #expect(!rlIcon.intersects(fullLine))
        #expect(!rlIcon.intersects(nextLine))
        #expect(rlIcon.minX < lrIcon.minX)
    }

    @Test func iconFallsBackAboveLineWhenHorizontalRoomIsInsufficient() {
        let inset = visible.insetBy(dx: L.margin, dy: L.margin)

        // Full-width line flush with right edge: L→R has no room to the right -> falls back above the line.
        let rightEdgeLine = CGRect(x: 400, y: 700, width: inset.maxX - 400 - 4, height: 18)
        let rightSel = CGRect(x: 1500, y: 700, width: 200, height: 18)
        let lrFallback = L.iconFrame(mouseDown: CGPoint(x: 1500, y: 709),
                                     mouseUp: CGPoint(x: 1700, y: 709),
                                     selectionBounds: rightSel,
                                     lineBounds: rightEdgeLine,
                                     in: visible)
        #expect(inset.contains(lrFallback))
        #expect(lrFallback.minY == rightEdgeLine.maxY + L.iconVerticalGap)

        // Full-width line flush with left edge: R→L has no room to the left -> falls back above the line.
        let leftEdgeLine = CGRect(x: inset.minX + 4, y: 700, width: 900, height: 18)
        let leftSel = CGRect(x: 100, y: 700, width: 200, height: 18)
        let rlFallback = L.iconFrame(mouseDown: CGPoint(x: 300, y: 709),
                                     mouseUp: CGPoint(x: 100, y: 709),
                                     selectionBounds: leftEdgeLine.intersection(leftSel),
                                     lineBounds: leftEdgeLine,
                                     in: visible)
        #expect(inset.contains(rlFallback))
        #expect(rlFallback.minY == leftEdgeLine.maxY + L.iconVerticalGap)

        // Also flush with top edge: flips below as last resort while staying inside visible bounds.
        let topRightLine = CGRect(x: 400, y: inset.maxY - 20, width: inset.maxX - 400 - 4, height: 18)
        let topFallback = L.iconFrame(mouseDown: CGPoint(x: 1500, y: topRightLine.midY),
                                      mouseUp: CGPoint(x: 1700, y: topRightLine.midY),
                                      selectionBounds: CGRect(x: 1500, y: topRightLine.minY, width: 200, height: 18),
                                      lineBounds: topRightLine,
                                      in: visible)
        #expect(inset.contains(topFallback))
        #expect(topFallback.maxY == topRightLine.minY - L.iconVerticalGap)
    }

    @Test func iconStaysStrictlyInsideOwningWindowFrame() {
        // TextEdit-like window centered on screen: plenty of screen room outside, tight padding inside.
        let win = CGRect(x: 480, y: 360, width: 840, height: 520) // x 480...1320, y 360...880
        let winInset = win.insetBy(dx: L.windowMargin, dy: L.windowMargin)

        // R→L: line starts 10 pt inside window's left border (not enough room for 28pt icon + 8pt gap inside window).
        // Must NOT spill outside win.minX; falls back above the line, left-aligned to selection start.
        let rlLine = CGRect(x: 490, y: 760, width: 788, height: 16)
        let sel = CGRect(x: 662, y: 760, width: 245, height: 16)
        let rlIcon = L.iconFrame(mouseDown: CGPoint(x: 907, y: 768),
                                 mouseUp: CGPoint(x: 662, y: 768),
                                 selectionBounds: sel,
                                 lineBounds: rlLine,
                                 windowFrame: win,
                                 in: visible)
        #expect(winInset.contains(rlIcon))
        #expect(rlIcon.minY == rlLine.maxY + L.iconVerticalGap)
        #expect(rlIcon.minX == sel.minX)

        // L→R with sufficient right margin inside window (42 pt): fits beside line end inside window.
        let lrFits = L.iconFrame(mouseDown: CGPoint(x: 662, y: 768),
                                 mouseUp: CGPoint(x: 907, y: 768),
                                 selectionBounds: sel,
                                 lineBounds: rlLine,
                                 windowFrame: win,
                                 in: visible)
        #expect(winInset.contains(lrFits))
        #expect(lrFits.minX == rlLine.maxX + L.iconGap)
        #expect(abs(lrFits.midY - rlLine.midY) <= 1)

        // L→R with tight right edge inside window (only 16 pt to right border): must NOT spill outside win.maxX;
        // falls back above the line, right-aligned to selection end.
        let tightRightLine = CGRect(x: 490, y: 760, width: 814, height: 16) // maxX = 1304, win.maxX = 1320
        let lrFallback = L.iconFrame(mouseDown: CGPoint(x: 662, y: 768),
                                     mouseUp: CGPoint(x: 907, y: 768),
                                     selectionBounds: sel,
                                     lineBounds: tightRightLine,
                                     windowFrame: win,
                                     in: visible)
        #expect(winInset.contains(lrFallback))
        #expect(lrFallback.minY == tightRightLine.maxY + L.iconVerticalGap)
        #expect(lrFallback.maxX == sel.maxX)

        // Near top of window with tight side edge: no room above inside window -> flips below, still inside window.
        let topLine = CGRect(x: 490, y: win.maxY - 24, width: 814, height: 16)
        let topSel = CGRect(x: 662, y: topLine.minY, width: 200, height: 16)
        let topIcon = L.iconFrame(mouseDown: CGPoint(x: 862, y: topLine.midY),
                                  mouseUp: CGPoint(x: 662, y: topLine.midY),
                                  selectionBounds: topSel,
                                  lineBounds: topLine,
                                  windowFrame: win,
                                  in: visible)
        #expect(winInset.contains(topIcon))
        #expect(topIcon.maxY == topLine.minY - L.iconVerticalGap)

        // Window partially off the right edge of display: constrained to intersection of window and display visibleFrame.
        let offscreenWin = CGRect(x: 1500, y: 360, width: 700, height: 520) // extends to x=2200 past visible.maxX=1920
        let partialLine = CGRect(x: 1510, y: 760, width: 400, height: 16)
        let partialSel = CGRect(x: 1600, y: 760, width: 180, height: 16)
        let clippedIcon = L.iconFrame(mouseDown: CGPoint(x: 1600, y: 768),
                                      mouseUp: CGPoint(x: 1780, y: 768),
                                      selectionBounds: partialSel,
                                      lineBounds: partialLine,
                                      windowFrame: offscreenWin,
                                      in: visible)
        #expect(visible.insetBy(dx: L.margin, dy: L.margin).contains(clippedIcon))
        #expect(offscreenWin.insetBy(dx: L.windowMargin, dy: L.windowMargin).contains(clippedIcon))
    }

    @Test func multiLineSelectionFollowsMouseUpLineAndDirection() {
        let tallBounds = CGRect(x: 450, y: 600, width: 400, height: 120) // spans y 600...720
        let bottomLine = CGRect(x: 450, y: 600, width: 400, height: 18)
        let topLine = CGRect(x: 450, y: 702, width: 400, height: 18)

        // Dragged downward to bottom line -> sits right of bottom line, centered on bottom line.
        let bottomIcon = L.iconFrame(mouseDown: CGPoint(x: 450, y: 710),
                                     mouseUp: CGPoint(x: 720, y: 609),
                                     selectionBounds: tallBounds,
                                     lineBounds: bottomLine,
                                     in: visible)
        #expect(bottomIcon.minX == bottomLine.maxX + L.iconGap)
        #expect(abs(bottomIcon.midY - bottomLine.midY) <= 1)

        // Dragged upward to top line -> sits left of top line, centered on top line.
        let topIcon = L.iconFrame(mouseDown: CGPoint(x: 720, y: 609),
                                  mouseUp: CGPoint(x: 500, y: 711),
                                  selectionBounds: tallBounds,
                                  lineBounds: topLine,
                                  in: visible)
        #expect(topIcon.maxX == topLine.minX - L.iconGap)
        #expect(abs(topIcon.midY - topLine.midY) <= 1)
        #expect(topIcon.minY > bottomIcon.minY + 80)
    }

    @Test func iconAndPopoverStayInsideScreenNearEdgesAndOnSecondaryDisplay() {
        let secondary = CGRect(x: 1920, y: 0, width: 1512, height: 944)
        let inset = secondary.insetBy(dx: L.margin, dy: L.margin)

        // Near bottom-right corner: icon falls back above and stays inside secondary display; popover flips above.
        let nearBottomRight = CGPoint(x: secondary.maxX - 10, y: secondary.minY + 14)
        let cornerLine = CGRect(x: nearBottomRight.x - 100, y: secondary.minY + 6, width: 100, height: 18)
        let icon = L.iconFrame(mouseDown: CGPoint(x: nearBottomRight.x - 100, y: nearBottomRight.y),
                               mouseUp: nearBottomRight,
                               selectionBounds: cornerLine,
                               lineBounds: cornerLine,
                               in: secondary)
        #expect(inset.contains(icon))
        #expect(icon.minY >= cornerLine.maxY)

        let popover = L.popoverFrame(mouseDown: CGPoint(x: nearBottomRight.x - 100, y: nearBottomRight.y),
                                     mouseUp: nearBottomRight,
                                     selectionBounds: cornerLine,
                                     lineBounds: cornerLine,
                                     size: CGSize(width: L.popoverWidth, height: 110),
                                     in: secondary)
        #expect(inset.contains(popover))
        #expect(popover.minY > secondary.minY + 24) // flipped above the line

        // Normal mid-screen selection: popover prefers directly below the line.
        let midLine = CGRect(x: 2200, y: 500, width: 180, height: 20)
        let below = L.popoverFrame(mouseDown: CGPoint(x: 2200, y: 510),
                                   mouseUp: CGPoint(x: 2380, y: 510),
                                   selectionBounds: midLine,
                                   lineBounds: midLine,
                                   size: CGSize(width: L.popoverWidth, height: 100),
                                   in: secondary)
        #expect(inset.contains(below))
        #expect(below.maxY == midLine.minY - L.popoverGap)
    }
}

@Suite("Selection auto-dismiss and model")
@MainActor
struct SelectionAutoDismissTests {
    @Test func autoDismissFiresAfterDelayAndCanBeCancelled() async {
        var fired = 0
        let timer = SelectionAutoDismiss(delay: 0.04, resumeDelay: 0.04) { fired += 1 }
        timer.start()
        for _ in 0..<40 where fired == 0 {
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(fired == 1)

        // Cancelled timer does not fire.
        timer.start()
        timer.cancel()
        try? await Task.sleep(for: .milliseconds(90))
        #expect(fired == 1)
    }

    @Test func hoveringPausesDismissUntilPointerLeaves() async {
        var fired = 0
        let timer = SelectionAutoDismiss(delay: 0.04, resumeDelay: 0.04) { fired += 1 }
        timer.start()
        timer.setHovering(true)
        try? await Task.sleep(for: .milliseconds(90))
        #expect(fired == 0 && timer.isPaused)

        timer.setHovering(false)
        for _ in 0..<40 where fired == 0 {
            try? await Task.sleep(for: .milliseconds(15))
        }
        #expect(fired == 1 && !timer.isPaused)
    }

    @Test func modelProducesTranslationOnlyResult() async {
        let model = SelectionTranslateModel(services: { [SelectionStubService(output: "现代 macOS 应用")] })
        model.translate("Modern macOS apps")
        for _ in 0..<200 where model.entries.contains(where: \.isLoading) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.primaryTranslation == "现代 macOS 应用")
        #expect(model.entries.count == 1)
        #expect(model.resolvedSource?.code == "en")
    }
}
