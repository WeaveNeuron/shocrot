import CoreGraphics
import SwiftUI
import Testing
@testable import Shocrot

/// The translation panel's height: its parts are capped so the whole panel fits the visible frame of its
/// display, however long the text (a full-screen OCR made it 1809 pt tall on a 982 pt display).
struct TranslatePanelLayoutTests {
    typealias L = TranslatePanelLayout
    let laptopVisible = CGRect(x: 0, y: 0, width: 1512, height: 949)
    let m = WindowPlacement.margin

    /// Header, input card and language bar at their tallest: the input editor at its cap, plus the card's
    /// caption row and padding, the 22 pt header, the 26 pt language bar and the spacing between them.
    var tallestChrome: CGFloat { 22 + (L.inputMaxHeight + 4 + 22 + 16) + 26 + 2 * L.spacing }

    @Test func longInputIsCappedAndScrolls() {
        #expect(L.inputHeight(natural: 1300) == L.inputMaxHeight)
        #expect(L.inputHeight(natural: 10) == L.inputMinHeight)
        #expect(L.inputHeight(natural: 90) == 90)
    }

    /// The fade hinting at more text below shows exactly when the text is cut off by the cap.
    @Test func onlyCappedInputFades() {
        #expect(L.inputOverflows(natural: 1300))
        #expect(L.inputOverflows(natural: L.inputMaxHeight + 1))
        #expect(!L.inputOverflows(natural: L.inputMaxHeight))
        #expect(!L.inputOverflows(natural: 20))
        #expect(L.inputFadeHeight < L.inputMinHeight / 2)
    }

    /// Reported after build 119: scrolled to the end, the last line still faded out. Each edge fades only while
    /// there is more text past it.
    @Test func theInputFadesOnlyTowardsMoreText() {
        let natural: CGFloat = 600  // capped at 140
        func fades(_ offset: CGFloat) -> (Bool, Bool) {
            let f = L.inputFades(natural: natural, scroll: TextScrollState(offset: offset, content: 600, visible: 140))
            return (f.top, f.bottom)
        }
        #expect(fades(0) == (false, true))       // at the top: more below
        #expect(fades(200) == (true, true))      // in the middle: more both ways
        #expect(fades(460) == (true, false))     // at the end: the last line is clear
        #expect(fades(459.5) == (true, false))   // a fraction from the end counts as the end
        #expect(fades(0.5) == (false, true))     // likewise at the top
    }

    @Test func textThatFitsNeverFades() {
        let short = L.inputFades(natural: 80, scroll: TextScrollState(offset: 0, content: 80, visible: 80))
        #expect(!short.top && !short.bottom)
        // Measured taller than the cap, but the editor shows it all (e.g. a trailing newline in the measurement).
        let fits = L.inputFades(natural: 150, scroll: TextScrollState(offset: 0, content: 140, visible: 140))
        #expect(!fits.top && !fits.bottom)
        #expect(L.inputFades(natural: 80, scroll: nil) == (false, false))
    }

    /// Before the editor's scroll position is known, capped text fades at the bottom only: it opens at its top.
    @Test func anUnknownScrollPositionFadesTheBottom() {
        #expect(L.inputFades(natural: 600, scroll: nil) == (false, true))
    }

    @Test func fullScreenTranslationFitsTheDisplay() {
        let maxPanel = WindowPlacement.maxHeight(in: laptopVisible)
        let results = L.resultsHeight(content: 2400, chrome: tallestChrome, maxPanelHeight: maxPanel)
        let height = L.panelHeight(chrome: tallestChrome, results: results)
        #expect(height <= maxPanel)
        #expect(results == L.resultsMaxHeight) // a 949 pt display has room for the usual cap
        // Placed anywhere and pulled back, the whole panel is inside the visible frame.
        let frame = CGRect(x: 546, y: 949 - 41 - height, width: 420, height: height)
        let fitted = WindowPlacement.onScreen(frame, screens: [(CGRect(x: 0, y: 0, width: 1512, height: 982),
                                                                laptopVisible)], fallback: nil)
        #expect(laptopVisible.insetBy(dx: m, dy: m).contains(fitted))
    }

    @Test func shortDisplayShrinksTheResultsInsteadOfOverflowing() {
        for visibleHeight in [768.0, 600, 500] as [CGFloat] {
            let visible = CGRect(x: 0, y: 0, width: 1366, height: visibleHeight)
            let maxPanel = WindowPlacement.maxHeight(in: visible)
            let results = L.resultsHeight(content: 5000, chrome: tallestChrome, maxPanelHeight: maxPanel)
            #expect(L.panelHeight(chrome: tallestChrome, results: results) <= maxPanel, "visible \(visibleHeight)")
            #expect(results >= L.resultsMinHeight)
        }
    }

    @Test func shortResultsKeepTheirOwnHeight() {
        let results = L.resultsHeight(content: 120, chrome: 150, maxPanelHeight: 933)
        #expect(results == 120)
        #expect(L.panelHeight(chrome: 150, results: 0) == L.topPadding + 150 + L.bottomPadding)
    }

    /// Capped results scroll, so their scroller must not be hidden: the system shows it when there is more.
    @Test func resultsScrollerFollowsTheSystemDefault() {
        #expect(L.resultsScrollIndicators == .automatic)
        #expect(L.resultsScrollIndicators != .never)
        #expect(L.resultsScrollIndicators != .hidden)
    }

    @Test func unknownDisplayHeightFallsBackToTheUsualCap() {
        #expect(L.resultsHeight(content: 2400, chrome: 200, maxPanelHeight: .greatestFiniteMagnitude) == L.resultsMaxHeight)
    }
}

/// The language menus' button titles: the target menu read "Automatic · Chinese (Simplified)" and was cut off.
struct LanguageMenuTitleTests {
    let zh = Language.named("zh-Hans")

    @Test func automaticShowsOnlyTheResolvedLanguage() {
        let t = LanguageMenuTitle(selection: nil, resolved: zh, automaticTitle: "Automatic")
        #expect(t.text == zh.name)
        #expect(t.showsAutomaticMark)
        #expect(t.full == "Automatic · \(zh.name)")
    }

    @Test func aChosenLanguageIsJustItsName() {
        let t = LanguageMenuTitle(selection: zh, resolved: Language.named("en"), automaticTitle: "Automatic")
        #expect(t == LanguageMenuTitle(selection: zh, resolved: nil, automaticTitle: "x"))
        #expect(t.text == zh.name && !t.showsAutomaticMark)
    }

    @Test func nothingResolvedYetShowsTheAutomaticTitle() {
        let t = LanguageMenuTitle(selection: nil, resolved: nil, automaticTitle: "Detect Language")
        #expect(t.text == "Detect Language" && !t.showsAutomaticMark)
    }

    /// Every title names at most one language, so none is longer than the longest language name.
    @Test func noTitleIsLongerThanOneLanguageName() {
        let longest = Language.all.map(\.name.count).max()!
        for language in Language.all {
            for t in [LanguageMenuTitle(selection: language, resolved: nil, automaticTitle: "Automatic"),
                      LanguageMenuTitle(selection: nil, resolved: language, automaticTitle: "Automatic")] {
                #expect(t.text.count <= longest)
            }
        }
    }
}

struct SpeakButtonLabelTests {
    /// The label used to stay "Read Aloud" while the button showed a stop symbol.
    @Test func theLabelFollowsTheState() {
        #expect(speakHelp(speaking: false) == L("translate.speak"))
        #expect(speakHelp(speaking: true) == L("translate.stopSpeaking"))
        #expect(speakHelp(speaking: true) != speakHelp(speaking: false))
    }
}
