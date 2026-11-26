import CoreGraphics
import Foundation
import Testing
@testable import Shocrot

private struct FastStubService: TranslationService {
    let name: String
    let symbol = "circle"
    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.yield("Translated: \(text)"); $0.finish() }
    }
}

@Suite("Translation panel stability")
struct TranslatePanelStabilityTests {
    typealias L = TranslatePanelLayout

    @Test func estimatedInputHeightTracksSelectionAndStaysBounded() {
        #expect(L.estimatedInputHeight(forSelection: nil) == 76)
        #expect(L.estimatedInputHeight(forSelection: .zero) == 76)
        #expect(L.estimatedInputHeight(forSelection: CGSize(width: 200, height: 24)) == 64)
        let paragraph = L.estimatedInputHeight(forSelection: CGSize(width: 670, height: 140))
        #expect(paragraph >= 100 && paragraph <= L.inputMaxHeight)
        #expect(L.estimatedInputHeight(forSelection: CGSize(width: 1200, height: 800)) == L.inputMaxHeight)
    }

    @Test func estimatedResultHeightScalesWithInputAndServiceCount() {
        let singleSmall = L.estimatedResultTextHeight(forInputHeight: 64, serviceCount: 1)
        let singleLarge = L.estimatedResultTextHeight(forInputHeight: 140, serviceCount: 1)
        #expect(singleSmall >= 64 && singleLarge > singleSmall && singleLarge <= 150)

        let multiLarge = L.estimatedResultTextHeight(forInputHeight: 140, serviceCount: 3)
        #expect(multiLarge >= 48 && multiLarge < singleLarge)
    }

    @MainActor
    @Test func beginRecognizingPrePopulatesPlaceholderResultsAndClearsStaleLanguages() async {
        let model = TranslateModel(services: { [FastStubService(name: "Apple"), FastStubService(name: "Google")] })
        model.query("Hello world")
        for _ in 0..<200 where model.results.contains(where: \.isLoading) {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(model.resolvedSource != nil)
        #expect(model.resolvedTarget != nil)

        model.beginRecognizing(selectionSize: CGSize(width: 600, height: 150))
        #expect(model.isRecognizing)
        #expect(model.input.isEmpty)
        #expect(model.resolvedSource == nil)
        #expect(model.resolvedTarget == nil)
        #expect(model.recognizingSelectionSize == CGSize(width: 600, height: 150))
        #expect(model.results.count == 2)
        #expect(model.results.allSatisfy { $0.isLoading && $0.text.isEmpty })
        model.endRecognizing()
    }

    @MainActor
    @Test func clearAndEmptyTranslateAlsoClearResolvedTarget() async {
        let model = TranslateModel(services: { [FastStubService(name: "Apple")] })
        model.query("Hello world")
        #expect(model.resolvedTarget != nil)

        model.clear()
        #expect(model.resolvedSource == nil)
        #expect(model.resolvedTarget == nil)
        #expect(model.results.isEmpty)

        model.query("Hello again")
        #expect(model.resolvedTarget != nil)
        model.input = "   "
        model.translate()
        #expect(model.resolvedSource == nil)
        #expect(model.resolvedTarget == nil)
    }
}
