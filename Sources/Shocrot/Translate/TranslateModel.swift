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
    @Published private(set) var detected: Language?
    @Published private(set) var resolvedTarget: Language?
    @Published private(set) var results: [ServiceResult] = []
    @Published private(set) var definition: String?
    @Published private(set) var hasServices = true

    private var tasks: [Task<Void, Never>] = []

    func translate() {
        tasks.forEach { $0.cancel() }
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let services = TranslationServices.enabled
        hasServices = !services.isEmpty
        guard !text.isEmpty else {
            results = []; definition = nil; detected = nil
            return
        }
        let from = source ?? Language.detect(text) ?? Language.named("en")
        let to = target ?? Language.target(for: from)
        detected = from
        resolvedTarget = to
        definition = SystemDictionary.define(text)
        results = services.enumerated().map { ServiceResult(id: $0, name: $1.name, symbol: $1.symbol) }
        tasks = services.enumerated().map { index, service in
            Task { [weak self] in
                do {
                    for try await partial in service.translate(text, from: from, to: to) {
                        self?.update(index) { $0.text = partial }
                    }
                    self?.update(index) { $0.isLoading = false }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.update(index) { $0.error = error; $0.isLoading = false }
                }
            }
        }
    }

    func query(_ text: String) {
        input = text
        translate()
    }

    /// Swaps the resolved languages and re-runs the query.
    func swapLanguages() {
        guard let from = detected, let to = resolvedTarget else { return }
        source = to
        target = from
        translate()
    }

    func clear() {
        tasks.forEach { $0.cancel() }
        input = ""
        results = []
        definition = nil
        detected = nil
    }

    private func update(_ index: Int, _ change: (inout ServiceResult) -> Void) {
        guard results.indices.contains(index) else { return }
        change(&results[index])
    }
}
