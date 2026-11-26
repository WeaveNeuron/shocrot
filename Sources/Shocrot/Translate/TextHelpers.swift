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

/// Reads the text selected in the frontmost app strictly through the Accessibility API (no ⌘C / clipboard touch).
enum SelectionReader {
    static var isTrusted: Bool { AXSelectionReader.isTrusted }

    static let log = AXSelectionReader.log

    static func selectedText() async -> String? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let snapshot = await AXSelectionReader.readSelection(pid: front.processIdentifier,
                                                             atAppKitPoint: NSEvent.mouseLocation,
                                                             primaryScreenHeight: primaryHeight)
        let app = front.bundleIdentifier ?? "?"
        log.info("selection via AX from \(app, privacy: .public): \(snapshot?.text.count ?? 0) chars")
        return snapshot?.text
    }
}
