import Foundation
import Testing
@testable import Shocrot

/// A service that answers at once with a fixed sentence in the target language, so the tests need no network
/// or downloaded languages, and language detection on the answer is reliable.
private struct StubService: TranslationService {
    let name = "Stub"
    let symbol = "circle"
    static let chinese = "今天天气很好，我们一起去公园散步吧。"
    static let english = "The weather is lovely today, let us take a walk in the park together."
    static let french = "Il fait très beau aujourd'hui, allons nous promener ensemble dans le parc."

    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        let answer = target.isChinese ? Self.chinese : target.code == "fr" ? Self.french : Self.english
        return AsyncThrowingStream { $0.yield(answer); $0.finish() }
    }
}

@MainActor
private func model(_ input: String, source: Language? = nil, target: Language? = nil) async -> TranslateModel {
    let model = TranslateModel(services: { [StubService()] })
    model.source = source
    model.target = target
    model.input = input
    model.translate()
    await settle(model)
    return model
}

@MainActor
private func settle(_ model: TranslateModel) async {
    for _ in 0..<500 where model.results.contains(where: \.isLoading) {
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private let en = Language.named("en"), zh = Language.named("zh-Hans"), fr = Language.named("fr")

@MainActor
struct TranslateModelSwapTests {
    /// The reported bug: swapping turned Detect / Automatic into fixed languages. Both stay automatic now and the
    /// translation becomes the input, so the query runs the other way by itself.
    @Test func detectAndAutomaticStayAndTheTranslationBecomesTheInput() async {
        let m = await model(StubService.english, target: nil)
        let translation = try! #require(m.firstTranslation)
        m.swapLanguages()
        await settle(m)
        #expect(m.source == nil)
        #expect(m.target == nil)
        #expect(m.input == translation)
        #expect(m.resolvedSource == m.detected)
    }

    @Test func detectStaysAndAChosenTargetTakesTheDetectedLanguage() async {
        let m = await model(StubService.english, target: zh)
        #expect(m.detected == en)
        m.swapLanguages()
        await settle(m)
        #expect(m.source == nil)
        #expect(m.target == en)
        #expect(m.input == StubService.chinese)
        #expect(m.detected == zh)
        #expect(m.firstTranslation == StubService.english)
    }

    @Test func aChosenSourceTakesTheResolvedTargetAndAutomaticStays() async {
        let m = await model(StubService.french, source: fr, target: nil)
        let resolvedTarget = try! #require(m.resolvedTarget)
        m.swapLanguages()
        await settle(m)
        #expect(m.source == resolvedTarget)
        #expect(m.target == nil)
    }

    @Test func twoChosenLanguagesSwapEvenWithoutText() async {
        let m = await model("", source: en, target: zh)
        #expect(m.canSwap)
        m.swapLanguages()
        #expect(m.source == zh)
        #expect(m.target == en)
        #expect(m.input == "")
    }

    @Test func nothingToSwapWithDetectAndNoTranslation() async {
        let m = await model("", target: zh)
        #expect(!m.canSwap)
        m.swapLanguages()
        #expect(m.source == nil)
        #expect(m.target == zh)
    }

    @Test func swappedLanguagesTable() {
        typealias M = TranslateModel
        #expect(M.swapped(source: nil, target: nil, resolvedSource: en, resolvedTarget: zh) == (nil, nil))
        #expect(M.swapped(source: nil, target: zh, resolvedSource: en, resolvedTarget: zh) == (nil, en))
        #expect(M.swapped(source: en, target: nil, resolvedSource: en, resolvedTarget: zh) == (zh, nil))
        #expect(M.swapped(source: en, target: zh, resolvedSource: en, resolvedTarget: zh) == (zh, en))
        // Nothing resolved yet: a chosen language keeps itself rather than turning automatic.
        #expect(M.swapped(source: nil, target: zh, resolvedSource: nil, resolvedTarget: nil) == (nil, zh))
    }
}

/// The caption under the input (06c in the QA: English text captioned "Chinese (Simplified)").
@MainActor
struct TranslateSourceCaptionTests {
    @Test func detectShowsWhatWasDetected() async {
        let m = await model(StubService.english)
        #expect(m.sourceCaption == L("translate.detected", en.name))
    }

    /// The cause of 06c: an earlier swap had fixed the source to Chinese, and the caption echoed the chosen
    /// source as if detected. Detection itself was right; the caption now says the text looks like English.
    @Test func aChosenSourceThatDisagreesWithTheTextSaysSo() async {
        let m = await model(StubService.english, source: zh)
        #expect(m.detected == en)
        #expect(m.resolvedSource == zh)
        #expect(m.sourceCaption == L("translate.sourceLooksLike", zh.name, en.name))
    }

    @Test func aChosenSourceThatMatchesIsJustItsName() async {
        let m = await model(StubService.english, source: en)
        #expect(m.sourceCaption == en.name)
        let hant = await model(StubService.chinese, source: Language.named("zh-Hant"))
        #expect(hant.sourceCaption == Language.named("zh-Hant").name)
    }

    @Test func noTextNoCaption() async {
        let m = await model("  ")
        #expect(m.sourceCaption == nil)
        let cleared = await model(StubService.english)
        cleared.clear()
        #expect(cleared.sourceCaption == nil)
    }
}
