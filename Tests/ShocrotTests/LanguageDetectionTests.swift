import Testing
@testable import Shocrot

/// Short-text language detection: a few English words were taken for Indonesian, Turkish, Portuguese…
struct LanguageDetectionTests {
    /// Titles, labels and menu items of two or three words, several of which the recognizer alone got wrong.
    static let shortEnglish = [
        "Mac Studio Setup", "Turbo", "Labkeeper Round 4d Design", "Copy Translation", "Project Roadmap",
        "Data Pipeline", "Hello world", "Settings", "Review", "Open File", "Read Aloud", "Good morning",
        "New Conversation", "Customer Feedback", "Weekly Report", "Release Notes", "Sign in", "Turn On",
    ]

    /// Real short sentences in other languages, several in the very languages English was mistaken for.
    static let shortOther: [(String, String)] = [
        ("Selamat pagi", "id"), ("Terima kasih banyak", "id"), ("Saya lapar", "id"),
        ("Teşekkür ederim", "tr"), ("Günaydın arkadaşlar", "tr"),
        ("Obrigado pela ajuda", "pt"), ("Hoje está calor", "pt"), ("Até logo", "pt"),
        ("Merci beaucoup", "fr"), ("Je suis fatigué", "fr"), ("Bonjour à tous", "fr"),
        ("Guten Morgen", "de"), ("Ich bin müde", "de"), ("Wie geht es dir", "de"),
        ("Buenos días", "es"), ("Estoy cansado", "es"),
        ("Grazie mille", "it"), ("Sono stanco", "it"), ("Ciao bella", "it"),
        ("Dziękuję bardzo", "pl"), ("Dzień dobry", "pl"),
        ("Goedemorgen", "nl"), ("Dank je wel", "nl"),
        ("Xin chào bạn", "vi"),
        ("Добрый день", "ru"), ("Привіт друзі", "uk"), ("こんにちは", "ja"), ("안녕하세요", "ko"),
    ]

    @Test(arguments: shortEnglish)
    func shortEnglishIsEnglish(_ text: String) {
        #expect(Language.detect(text)?.code == "en", "\(text)")
    }

    @Test(arguments: shortOther)
    func shortSentencesInOtherLanguagesKeepTheirLanguage(_ sample: (String, String)) {
        #expect(Language.detect(sample.0)?.code == sample.1, "\(sample.0)")
    }

    @Test func chineseIsStillChinese() {
        #expect(Language.detect("你好")?.isChinese == true)
        #expect(Language.detect("今天天气很好")?.isChinese == true)
    }

    /// Longer text gets no English prior: the recognizer has evidence enough on its own.
    @Test func longTextIsNotNudgedTowardsEnglish() {
        let indonesian = "Saya pergi ke pasar pagi ini untuk membeli sayur dan buah segar bersama ibu saya."
        #expect(!Language.isShortLatin(indonesian))
        #expect(Language.detect(indonesian)?.code == "id")
    }

    /// Short Latin text the recognizer can't place even with the prior (keyboard mash, OCR noise; its best guess
    /// is Polish at 0.33 and 0.41) falls back to English.
    @Test func uncertainShortLatinFallsBackToEnglish() {
        #expect(Language.detect("zzz")?.code == "en")
        #expect(Language.detect("asdf jkl")?.code == "en")
    }

    /// A letter only one language uses still decides, prior or not: the dotless ı is Turkish.
    @Test func aDistinctiveLetterOutweighsThePrior() {
        #expect(Language.detect("Turbo v ı|*")?.code == "tr")
    }

    @Test func whatCountsAsShortLatin() {
        #expect(Language.isShortLatin("Mac Studio Setup"))
        #expect(Language.isShortLatin("Xin chào bạn"))  // Vietnamese tone marks are Latin Extended Additional
        #expect(Language.isShortLatin("Teşekkür ederim"))
        #expect(!Language.isShortLatin("Добрый день"))
        #expect(!Language.isShortLatin("你好"))
        #expect(!Language.isShortLatin("Hello 你好"))
        #expect(!Language.isShortLatin("1234 !?"))  // no letters
        #expect(Language.isShortLatin(String(repeating: "word ", count: 10)))  // 40 letters
        #expect(!Language.isShortLatin(String(repeating: "word ", count: 11)))  // 44 letters
    }
}
