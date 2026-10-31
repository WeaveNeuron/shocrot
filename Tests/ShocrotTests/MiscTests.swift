import Carbon.HIToolbox
import Testing
@testable import Shocrot

@Suite("Shortcuts")
struct ShortcutTests {
    @Test func displayStringOrdersModifiersLikeMacOS() {
        let hk = HotKey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey | shiftKey))
        #expect(hk.displayString == "⌥⇧A")
        let all = HotKey(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        #expect(all.displayString == "⌃⌥⇧⌘X")
    }

    @Test func keyCapsKeepMultiCharacterKeysWhole() {
        #expect(KeyCaps.parts(of: "⌥⇧A") == ["⌥", "⇧", "A"])
        #expect(KeyCaps.parts(of: "⌥F12") == ["⌥", "F12"])
        #expect(KeyCaps.parts(of: "F5") == ["F5"])
        #expect(KeyCaps.parts(of: "—") == ["—"])
    }
}

@Suite("Language")
struct LanguageTests {
    @Test func detectsCommonLanguages() {
        #expect(Language.detect("Screenshots are the fastest way to share what you see.")?.code == "en")
        #expect(Language.detect("一个按键，截图、标注、贴图、识别与翻译。")?.code == "zh-Hans")
        #expect(Language.detect("スクリーンショットを撮って翻訳します。")?.code == "ja")
    }

    @Test func unknownCodesFallBackToTheCode() {
        #expect(Language.named("xx").name == "xx")
        #expect(Language.named("zh-Hans").name == "简体中文")
    }
}
