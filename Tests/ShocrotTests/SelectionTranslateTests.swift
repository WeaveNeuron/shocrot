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

    /// Left-to-right drag: mouse releases at the end -> icon appears near the end (right).
    /// Right-to-left drag: mouse releases at the start -> icon appears near the start (left).
    @Test func iconFollowsMouseUpDirection() {
        let lineBounds = CGRect(x: 450, y: 700, width: 260, height: 20)

        let lrIcon = L.iconFrame(mouseDown: CGPoint(x: 450, y: 710),
                                 mouseUp: CGPoint(x: 710, y: 710),
                                 selectionBounds: lineBounds,
                                 in: visible)
        #expect(lrIcon.minX >= 710) // at the end
        #expect(lrIcon.maxY == lineBounds.minY - L.iconGap)

        let rlIcon = L.iconFrame(mouseDown: CGPoint(x: 710, y: 710),
                                 mouseUp: CGPoint(x: 450, y: 710),
                                 selectionBounds: lineBounds,
                                 in: visible)
        #expect(rlIcon.maxX <= 450) // at the start
        #expect(rlIcon.maxY == lineBounds.minY - L.iconGap)
        #expect(rlIcon.minX < lrIcon.minX)
    }

    @Test func multiLineSelectionFollowsMouseUpLineRatherThanJumpingToTop() {
        let tallBounds = CGRect(x: 450, y: 600, width: 400, height: 120) // spans y 600...720
        // Dragged downward to bottom line (y = 610)
        let bottomIcon = L.iconFrame(mouseDown: CGPoint(x: 450, y: 710),
                                     mouseUp: CGPoint(x: 720, y: 610),
                                     selectionBounds: tallBounds,
                                     in: visible)
        #expect(abs(bottomIcon.maxY - (610 - 11 - L.iconGap)) <= 1)

        // Dragged upward to top line (y = 710)
        let topIcon = L.iconFrame(mouseDown: CGPoint(x: 720, y: 610),
                                  mouseUp: CGPoint(x: 450, y: 710),
                                  selectionBounds: tallBounds,
                                  in: visible)
        #expect(topIcon.minY > bottomIcon.minY + 80)
    }

    @Test func iconAndPopoverStayInsideScreenNearEdgesAndOnSecondaryDisplay() {
        let secondary = CGRect(x: 1920, y: 0, width: 1512, height: 944)
        let inset = secondary.insetBy(dx: L.margin, dy: L.margin)

        // Near bottom-right corner: icon and popover must flip above and stay inside secondary display.
        let nearBottomRight = CGPoint(x: secondary.maxX - 10, y: secondary.minY + 14)
        let icon = L.iconFrame(mouseDown: CGPoint(x: nearBottomRight.x - 100, y: nearBottomRight.y),
                               mouseUp: nearBottomRight,
                               selectionBounds: CGRect(x: nearBottomRight.x - 100, y: secondary.minY + 6, width: 100, height: 18),
                               in: secondary)
        #expect(inset.contains(icon))

        let popover = L.popoverFrame(mouseDown: CGPoint(x: nearBottomRight.x - 100, y: nearBottomRight.y),
                                     mouseUp: nearBottomRight,
                                     selectionBounds: CGRect(x: nearBottomRight.x - 100, y: secondary.minY + 6, width: 100, height: 18),
                                     size: CGSize(width: L.popoverWidth, height: 110),
                                     in: secondary)
        #expect(inset.contains(popover))
        #expect(popover.minY > secondary.minY + 24) // flipped above the line

        // Normal mid-screen selection: popover prefers directly below the line.
        let midLine = CGRect(x: 2200, y: 500, width: 180, height: 20)
        let below = L.popoverFrame(mouseDown: CGPoint(x: 2200, y: 510),
                                   mouseUp: CGPoint(x: 2380, y: 510),
                                   selectionBounds: midLine,
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
        try? await Task.sleep(for: .milliseconds(90))
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
        try? await Task.sleep(for: .milliseconds(90))
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
