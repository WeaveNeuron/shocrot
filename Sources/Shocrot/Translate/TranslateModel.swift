import Foundation

/// State of one translation query, fanned out to every enabled service.
@MainActor
final class TranslateModel: ObservableObject {
    struct ServiceResult: Identifiable {
        let id: Int
        let name: String
        let symbol: String
        var text = ""
        var error: Error?
        var isLoading = true
    }

    @Published var input = ""
    @Published var source: Language?  // nil = detect
    @Published var target: Language?  // nil = automatic
    @Published var pinned = false
    /// Screenshot translation shows the panel right away while OCR is still running.
    @Published var isRecognizing = false
    /// Set when OCR takes noticeably longer than usual (e.g. first-ever model compilation).
    @Published var isSlowRecognizing = false
    /// The captured selection size (in points) driving stable placeholder sizing while OCR runs.
    @Published var recognizingSelectionSize: CGSize?
    /// The tallest the panel may get: its display's visible height less margins. Set by `TranslatePanel`.
    @Published var maxPanelHeight: CGFloat = .greatestFiniteMagnitude
    /// The language the input looks like (nil when unsure), whatever source is chosen.
    @Published private(set) var detected: Language?
    /// The languages the current query runs between: the chosen ones, or what Detect / Automatic resolved to.
    @Published private(set) var resolvedSource: Language?
    @Published private(set) var resolvedTarget: Language?
    @Published private(set) var results: [ServiceResult] = []
    @Published private(set) var definition: String?
    @Published private(set) var hasServices = true

    private var tasks: [Task<Void, Never>] = []
    private var slowHintTask: Task<Void, Never>?
    private let services: () -> [TranslationService]

    init(services: @escaping () -> [TranslationService] = { TranslationServices.enabled }) {
        self.services = services
    }

    /// Prepares the panel for an incoming screenshot OCR with stable placeholder result cards right away.
    func beginRecognizing(selectionSize: CGSize?) {
        tasks.forEach { $0.cancel() }
        tasks = []
        slowHintTask?.cancel()
        input = ""
        definition = nil
        detected = nil
        resolvedSource = nil
        resolvedTarget = nil
        isRecognizing = true
        isSlowRecognizing = false
        recognizingSelectionSize = selectionSize
        let enabled = services()
        hasServices = !enabled.isEmpty
        results = enabled.enumerated().map { ServiceResult(id: $0, name: $1.name, symbol: $1.symbol) }
        slowHintTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, let self, self.isRecognizing else { return }
            self.isSlowRecognizing = true
        }
    }

    func endRecognizing() {
        slowHintTask?.cancel()
        slowHintTask = nil
        isRecognizing = false
        isSlowRecognizing = false
        recognizingSelectionSize = nil
    }

    func translate() {
        tasks.forEach { $0.cancel() }
        endRecognizing()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = services()
        hasServices = !services.isEmpty
        guard !text.isEmpty else {
            results = []; definition = nil; detected = nil; resolvedSource = nil; resolvedTarget = nil
            return
        }
        let tDetect = PerfLog.now()
        detected = Language.detect(text)
        let detectMs = PerfLog.elapsedMs(since: tDetect)
        let from = source ?? detected ?? Language.named("en")
        let to = target ?? Language.target(for: from)
        resolvedSource = from
        resolvedTarget = to
        let tDict = PerfLog.now()
        definition = SystemDictionary.define(text)
        let dictMs = PerfLog.elapsedMs(since: tDict)
        PerfLog.logger.notice("translate.prepare detect_ms=\(detectMs, format: .fixed(precision: 1), privacy: .public) dict_ms=\(dictMs, format: .fixed(precision: 1), privacy: .public) chars=\(text.count, privacy: .public)")
        results = services.enumerated().map { ServiceResult(id: $0, name: $1.name, symbol: $1.symbol) }
        tasks = services.enumerated().map { index, service in
            Task { [weak self] in
                do {
                    for try await partial in service.translate(text, from: from, to: to) {
                        guard !Task.isCancelled else { return }
                        self?.update(index) { $0.text = partial }
                    }
                    // A cancelled stream ends normally; `results` already belongs to the newer query.
                    guard !Task.isCancelled else { return }
                    self?.update(index) { $0.isLoading = false }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.update(index) { $0.error = error; $0.isLoading = false }
                }
            }
        }
    }

    func query(_ text: String) {
        endRecognizing()
        input = text
        translate()
    }

    /// The first finished translation, if any.
    var firstTranslation: String? {
        results.first { $0.error == nil && !$0.isLoading && !$0.text.isEmpty }?.text
    }

    /// Swap needs something to turn around: a finished translation, or two chosen languages.
    var canSwap: Bool { firstTranslation != nil || (source != nil && target != nil) }

    /// Turns the query around the way translation apps do (Apple Translate, DeepL): the translation becomes the
    /// input, chosen languages trade places, and Detect / Automatic stay automatic: on the swapped text they
    /// resolve to the swapped pair by themselves. With no translation yet, only two chosen languages swap.
    func swapLanguages() {
        guard canSwap else { return }
        let languages = Self.swapped(source: source, target: target,
                                     resolvedSource: resolvedSource, resolvedTarget: resolvedTarget)
        if let translation = firstTranslation { input = translation }
        source = languages.source
        target = languages.target
        translate()
    }

    /// The languages after a swap: each chosen one takes the other side's language (as resolved, when that side
    /// is automatic); Detect and Automatic stay as they are.
    static func swapped(source: Language?, target: Language?, resolvedSource: Language?, resolvedTarget: Language?)
        -> (source: Language?, target: Language?) {
        (source.map { target ?? resolvedTarget ?? $0 }, target.map { source ?? resolvedSource ?? $0 })
    }

    /// The caption under the input: what Detect found, or the chosen source, noting when the text looks like
    /// another language (Chinese variants aside, which detection can't tell apart reliably).
    var sourceCaption: String? {
        guard let from = resolvedSource else { return nil }
        guard let source else { return L("translate.detected", from.name) }
        if let detected, detected != source, !(detected.isChinese && source.isChinese) {
            return L("translate.sourceLooksLike", source.name, detected.name)
        }
        return source.name
    }

    func clear() {
        tasks.forEach { $0.cancel() }
        tasks = []
        endRecognizing()
        input = ""
        results = []
        definition = nil
        detected = nil
        resolvedSource = nil
        resolvedTarget = nil
    }

    private func update(_ index: Int, _ change: (inout ServiceResult) -> Void) {
        guard results.indices.contains(index) else { return }
        change(&results[index])
    }
}
