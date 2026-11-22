import CoreGraphics
import Testing
@testable import Shocrot

/// The translation panel's height cap as a whole: for any display, any amount of text and any chrome height
/// the header, input and language bar can take, the panel fits its display's visible frame, and the results
/// list (the only part that gives way) behaves sensibly as things grow.
struct TranslatePanelHeightCapTests {
    typealias L = TranslatePanelLayout
    let m = WindowPlacement.margin

    /// Header, input card and language bar: with a one-line input, and with the input at its cap.
    var shortestChrome: CGFloat { 22 + (L.inputMinHeight + 4 + 22 + 16) + 26 + 2 * L.spacing }
    var tallestChrome: CGFloat { 22 + (L.inputMaxHeight + 4 + 22 + 16) + 26 + 2 * L.spacing }

    let visibleHeights: [CGFloat] = [400, 500, 575, 683, 768, 949, 1017, 1415, 2160]
    let contents: [CGFloat] = [0, 1, 60, 200, 459, 460, 461, 900, 5000]

    private func panelHeight(visible: CGFloat, chrome: CGFloat, content: CGFloat) -> (panel: CGFloat, results: CGFloat) {
        let cap = WindowPlacement.maxHeight(in: CGRect(x: 0, y: 0, width: 1512, height: visible))
        let results = L.resultsHeight(content: content, chrome: chrome, maxPanelHeight: cap)
        return (L.panelHeight(chrome: chrome, results: results), results)
    }

    /// Whenever the display has room for the chrome and the minimum results, the whole panel fits.
    @Test func thePanelFitsEveryDisplayTallEnoughForItsChrome() {
        for visible in visibleHeights {
            let cap = visible - 2 * m
            for chrome in stride(from: shortestChrome, through: tallestChrome, by: 16) {
                guard L.panelHeight(chrome: chrome, results: L.resultsMinHeight) <= cap else { continue }
                for content in contents {
                    let (panel, results) = panelHeight(visible: visible, chrome: chrome, content: content)
                    #expect(panel <= cap, "visible \(visible), chrome \(chrome), content \(content)")
                    #expect(results >= 0 && results <= content && results <= L.resultsMaxHeight)
                }
            }
        }
    }

    @Test func moreTextNeverShrinksTheResults() {
        for visible in visibleHeights {
            var last: CGFloat = 0
            for content in stride(from: 0 as CGFloat, through: 3000, by: 37) {
                let (_, results) = panelHeight(visible: visible, chrome: tallestChrome, content: content)
                #expect(results >= last, "visible \(visible), content \(content)")
                last = results
            }
        }
    }

    /// Dragged to a taller display, the panel can show more; to a shorter one, less, and it still fits.
    @Test func aTallerDisplayNeverShowsFewerResults() {
        var last: CGFloat = 0
        for visible in visibleHeights {
            let (_, results) = panelHeight(visible: visible, chrome: tallestChrome, content: 5000)
            #expect(results >= last, "visible \(visible)")
            last = results
        }
    }

    @Test func shortResultsAreShownWhole() {
        for visible in visibleHeights where visible >= 683 {
            let (_, results) = panelHeight(visible: visible, chrome: tallestChrome, content: 60)
            #expect(results == 60, "visible \(visible)")
        }
    }

    @Test func noResultsAddNoSpacing() {
        let (panel, results) = panelHeight(visible: 949, chrome: shortestChrome, content: 0)
        #expect(results == 0)
        #expect(panel == L.topPadding + shortestChrome + L.bottomPadding)
    }

    /// A display too short for the chrome and the minimum results: the panel is taller than the display, but
    /// pulled back on screen its header (the drag handle and the close button) is at the top, reachable.
    @Test func onADisplayTooShortTheHeaderStaysReachable() {
        let visible = CGRect(x: 0, y: 0, width: 1024, height: 300)
        let (panel, results) = panelHeight(visible: visible.height, chrome: tallestChrome, content: 5000)
        #expect(results == L.resultsMinHeight)
        #expect(panel > WindowPlacement.maxHeight(in: visible))
        let placed = CGRect(x: 200, y: -200, width: 420, height: panel)
        let f = WindowPlacement.onScreen(placed, screens: [(visible, visible)], fallback: nil)
        #expect(f.maxY == visible.maxY - m)
        #expect(f.minX >= visible.minX + m && f.maxX <= visible.maxX - m)
    }

    @Test func theInputGrowsWithItsTextUpToTheCap() {
        var last: CGFloat = 0
        for natural in stride(from: 0 as CGFloat, through: 400, by: 7) {
            let h = L.inputHeight(natural: natural)
            #expect(h >= L.inputMinHeight && h <= L.inputMaxHeight)
            #expect(h >= last)
            last = h
        }
    }
}
