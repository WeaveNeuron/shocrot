import CoreGraphics
import Testing
@testable import Shocrot

/// Builds a result from lines laid out top to bottom, like Vision returns them (normalized, origin bottom-left).
private func result(_ rows: [(String, x: CGFloat, width: CGFloat)], lineHeight: CGFloat = 0.04, gap: CGFloat = 0.01,
                    paragraphBreaks: Set<Int> = []) -> OCRResult {
    var y: CGFloat = 0.95
    var lines: [OCRLine] = []
    for (i, row) in rows.enumerated() {
        if paragraphBreaks.contains(i) { y -= lineHeight * 1.5 }
        lines.append(OCRLine(text: row.0, confidence: 1, box: CGRect(x: row.x, y: y - lineHeight, width: row.width, height: lineHeight)))
        y -= lineHeight + gap
    }
    return OCRResult(lines: lines, barcodes: [])
}

@Suite("OCR text reflow")
struct OCRTextTests {
    @Test func wrappedEnglishParagraphJoinsWithSpaces() {
        let r = result([("Screenshots are the fastest way", x: 0.1, width: 0.8),
                        ("to share what you see.", x: 0.1, width: 0.5)])
        #expect(r.text(keepLineBreaks: false) == "Screenshots are the fastest way to share what you see.")
        #expect(r.text(keepLineBreaks: true) == "Screenshots are the fastest way\nto share what you see.")
    }

    @Test func wrappedChineseJoinsWithoutSpaces() {
        let r = result([("一个按键，截图、标注、贴图、", x: 0.1, width: 0.8),
                        ("识别与翻译。", x: 0.1, width: 0.3)])
        #expect(r.text(keepLineBreaks: false) == "一个按键，截图、标注、贴图、识别与翻译。")
    }

    @Test func hyphenatedWordIsRejoined() {
        let r = result([("It concentrates on the essential trans-", x: 0.1, width: 0.8),
                        ("lation of ideas.", x: 0.1, width: 0.3)])
        #expect(r.text(keepLineBreaks: false) == "It concentrates on the essential translation of ideas.")
    }

    @Test func largeGapStartsNewParagraph() {
        let r = result([("First paragraph ends here.", x: 0.1, width: 0.8),
                        ("Second paragraph.", x: 0.1, width: 0.8)], paragraphBreaks: [1])
        #expect(r.text(keepLineBreaks: false) == "First paragraph ends here.\n\nSecond paragraph.")
    }

    @Test func listItemsStayOnTheirOwnLines() {
        let r = result([("Features:", x: 0.1, width: 0.8),
                        ("• Capture any area of the screen", x: 0.1, width: 0.8),
                        ("• Translate with Apple or Google", x: 0.1, width: 0.8),
                        ("1. Press the hotkey", x: 0.1, width: 0.8)])
        #expect(r.text(keepLineBreaks: false)
            == "Features:\n• Capture any area of the screen\n• Translate with Apple or Google\n1. Press the hotkey")
    }

    @Test func shortHeadingIsNotMergedIntoBody() {
        let r = result([("Getting Started", x: 0.1, width: 0.3),
                        ("Shocrot captures the screen and recognizes text", x: 0.1, width: 0.8)])
        #expect(r.text(keepLineBreaks: false) == "Getting Started\nShocrot captures the screen and recognizes text")
    }

    @Test func sameRowFragmentsShareALine() {
        let lines = [OCRLine(text: "Name", confidence: 1, box: CGRect(x: 0.1, y: 0.5, width: 0.2, height: 0.04)),
                     OCRLine(text: "Value", confidence: 1, box: CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.04))]
        #expect(OCRResult(lines: lines, barcodes: []).text(keepLineBreaks: false) == "Name  Value")
    }

    @Test func emptyResultIsEmpty() {
        #expect(OCRResult(lines: [], barcodes: []).text(keepLineBreaks: false).isEmpty)
    }
}

@Suite("OCR reading order")
struct OCRReadingOrderTests {
    private func line(_ text: String, x: CGFloat, midY: CGFloat, height: CGFloat = 0.04) -> OCRLine {
        OCRLine(text: text, confidence: 1, box: CGRect(x: x, y: midY - height / 2, width: 0.2, height: height))
    }

    @Test func rowsTopToBottomThenLeftToRight() {
        let lines = [line("b2", x: 0.5, midY: 0.50), line("a1", x: 0.1, midY: 0.80),
                     line("b1", x: 0.1, midY: 0.51), line("a2", x: 0.5, midY: 0.79)]
        #expect(VisionOCREngine.readingOrder(lines).map(\.text) == ["a1", "a2", "b1", "b2"])
    }

    /// A tall line shares a row with a line above and one below it that don't share a row with each other:
    /// a < b and b < c by position on the row, yet c is above a. A pairwise comparator has no consistent answer.
    @Test func orderDoesNotDependOnTheInputOrder() {
        let lines = [line("a", x: 0.1, midY: 0.500), line("b", x: 0.3, midY: 0.515, height: 0.10),
                     line("c", x: 0.5, midY: 0.530), line("next", x: 0.1, midY: 0.30)]
        for _ in 0..<50 {
            #expect(VisionOCREngine.readingOrder(lines.shuffled()).map(\.text) == ["b", "c", "a", "next"])
        }
    }

    @Test func slantedRowsDoNotChainTogether() {
        // Each line sits a little lower than the one before it, as on a tilted photo of a table.
        let lines = (0..<6).map { line("c\($0)", x: CGFloat($0) * 0.15, midY: 0.6 - CGFloat($0) * 0.015) }
        let order = VisionOCREngine.readingOrder(lines).map(\.text)
        #expect(Set(order) == Set(lines.map(\.text)))
        #expect(order.first == "c0")
    }
}
