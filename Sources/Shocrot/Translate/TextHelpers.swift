import AppKit
import AVFoundation
import CoreServices
import os

/// Word look-ups in the dictionaries installed in Dictionary.app (offline).
enum SystemDictionary {
    static func define(_ text: String) -> String? {
        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isWordLike(word) else { return nil }
        let range = CFRange(location: 0, length: (word as NSString).length)
        guard let raw = DCSCopyTextDefinition(nil, word as CFString, range)?.takeRetainedValue() as String? else { return nil }
        // Dictionary.app returns one long line; break it at sense markers.
        var out = raw
        for marker in [" ▶", " •", " ①", " ②", " ③", " ④", " ⑤", " PHRASES", " DERIVATIVES", " ORIGIN"] {
            out = out.replacingOccurrences(of: marker, with: "\n" + marker.trimmingCharacters(in: .whitespaces))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isWordLike(_ t: String) -> Bool {
        guard !t.isEmpty, t.count <= 30, !t.contains("\n") else { return false }
        if t.contains(where: \.isCJK) { return t.count <= 4 }
        return t.split(separator: " ").count <= 2 && t.allSatisfy { $0.isLetter || " -'".contains($0) }
    }

    static func open(_ word: String) {
        let q = word.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? word
        if let url = URL(string: "dict://\(q)") { NSWorkspace.shared.open(url) }
    }
}

/// Text-to-speech with system voices; one utterance at a time.
final class Speaker: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    static let shared = Speaker()
    private let synth = AVSpeechSynthesizer()
    @Published private(set) var speakingID: String?

    override init() {
        super.init()
        synth.delegate = self
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        speakingID = nil
    }

    func toggle(_ text: String, language: Language?, id: String) {
        let wasSpeaking = speakingID == id
        stop()
        guard !wasSpeaking, !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        let code = (language ?? Language.detect(text))?.code ?? "en"
        utterance.voice = AVSpeechSynthesisVoice(language: ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][code] ?? code)
        speakingID = id
        synth.speak(utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async { self.speakingID = nil }
    }
}

/// Reads the text selected in the frontmost app: Accessibility first, then a simulated ⌘C as fallback.
enum SelectionReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static let log = Logger(subsystem: "com.weaveneuron.shocrot", category: "selection")

    static func selectedText() async -> String? {
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        if let text = viaAccessibility(), !text.isEmpty {
            log.info("selection via AX from \(app, privacy: .public): \(text.count) chars")
            return text
        }
        let copied = await viaCopy()
        log.info("selection via ⌘C from \(app, privacy: .public): \(copied?.count ?? -1) chars")
        return copied
    }

    private static func viaAccessibility() -> String? {
        // Ask the frontmost app directly: the system-wide focus query fails on recent macOS.
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let element = focused else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sends ⌘C, reads the result, then restores the user's clipboard.
    private static func viaCopy() async -> String? {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
        } ?? []
        let before = pb.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: down) // C
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        for _ in 0..<12 where pb.changeCount == before { try? await Task.sleep(for: .milliseconds(25)) }
        guard pb.changeCount != before else { return nil }
        let text = pb.string(forType: .string)

        pb.clearContents()
        pb.writeObjects(saved.map { types in
            let item = NSPasteboardItem()
            types.forEach { item.setData($1, forType: $0) }
            return item
        })
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
