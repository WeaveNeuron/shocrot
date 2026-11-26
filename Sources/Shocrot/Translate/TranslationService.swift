import Foundation
import os
import Translation

/// A translation backend. Results stream in as the cumulative translated text,
/// so streaming engines (LLMs) and one-shot engines share the same UI.
protocol TranslationService {
    var name: String { get }
    var symbol: String { get }
    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error>
}

enum TranslationServices {
    /// The services the user has turned on, in display order. Add new engines here.
    static var enabled: [TranslationService] {
        let s = Settings.shared
        var services: [TranslationService] = []
        if s.appleTranslateEnabled { services.append(AppleTranslationService()) }
        if s.googleTranslateEnabled { services.append(GoogleTranslationService()) }
        if s.llm.enabled { services.append(LLMTranslationService(config: s.llm, apiKey: Keychain.llmAPIKey(for: s.llm.baseURL))) }
        return services
    }
}

struct TranslationFailure: LocalizedError {
    let errorDescription: String?
    var recovery: Recovery?

    enum Recovery { case downloadLanguages, openSettings }
}

/// Wraps an async producer into the stream shape used by `TranslationService`.
func translationStream(_ body: @escaping (AsyncThrowingStream<String, Error>.Continuation) async throws -> Void)
    -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let task = Task {
            do {
                try await body(continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Apple (on-device)

struct AppleTranslationService: TranslationService {
    var name: String { L("service.apple") }
    let symbol = "apple.logo"

    private struct PairKey: Hashable {
        let source: String
        let target: String
    }

    /// Caches only `.installed` pairs so newly downloaded languages are discovered immediately.
    private static let installedCache = OSAllocatedUnfairLock(initialState: [PairKey: (Locale.Language, Locale.Language)]())

    static func invalidateCache() {
        installedCache.withLock { $0.removeAll() }
    }

    /// Pre-checks availability for the user's primary/secondary language pair and warms `NLLanguageRecognizer`
    /// after launch without prompting for downloads or creating a UI session.
    static func warmUp(primary: String, secondary: String) {
        let p = Language.named(primary), s = Language.named(secondary)
        Task.detached(priority: .utility) {
            let t0 = PerfLog.now()
            _ = Language.detect("Hello world")
            _ = try? await installedPair(p, s)
            _ = try? await installedPair(s, p)
            PerfLog.logger.notice("translate.warmup done_ms=\(PerfLog.elapsedMs(since: t0), format: .fixed(precision: 1), privacy: .public) since_launch_ms=\(PerfLog.msSinceLaunch, format: .fixed(precision: 1), privacy: .public)")
        }
    }

    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        translationStream { continuation in
            let t0 = PerfLog.now()
            let (from, to) = try await Self.installedPair(source, target)
            let availMs = PerfLog.elapsedMs(since: t0)
            let t1 = PerfLog.now()
            let session = TranslationSession(installedSource: from, target: to)
            let out = try await session.translate(text).targetText
            let transMs = PerfLog.elapsedMs(since: t1)
            PerfLog.logger.notice("translate.apple avail_ms=\(availMs, format: .fixed(precision: 1), privacy: .public) translate_ms=\(transMs, format: .fixed(precision: 1), privacy: .public) total_ms=\(PerfLog.elapsedMs(since: t0), format: .fixed(precision: 1), privacy: .public) chars=\(text.count, privacy: .public) since_launch_ms=\(PerfLog.msSinceLaunch, format: .fixed(precision: 1), privacy: .public)")
            continuation.yield(out)
        }
    }

    /// Plain "en" resolves to en-US; if the user downloaded another variant (e.g. English UK), use that instead.
    private static func installedPair(_ source: Language, _ target: Language) async throws
        -> (Locale.Language, Locale.Language) {
        let key = PairKey(source: source.code, target: target.code)
        if let cached = installedCache.withLock({ $0[key] }) {
            return cached
        }
        let availability = LanguageAvailability()
        var supported = false
        for from in variants(source) {
            for to in variants(target) {
                switch await availability.status(from: from, to: to) {
                case .installed:
                    installedCache.withLock { $0[key] = (from, to) }
                    return (from, to)
                case .supported: supported = true
                default: break
                }
            }
        }
        guard supported else {
            throw TranslationFailure(errorDescription: L("error.appleUnsupported", source.name, target.name))
        }
        throw TranslationFailure(errorDescription: L("error.appleNeedsDownload", source.name, target.name),
                                 recovery: .downloadLanguages)
    }

    private static func variants(_ language: Language) -> [Locale.Language] {
        let regional: [String: [String]] = [
            "en": ["en-US", "en-GB", "en-AU", "en-IN"], "es": ["es-ES", "es-MX"], "pt": ["pt-BR", "pt-PT"],
            "fr": ["fr-FR", "fr-CA"], "zh-Hant": ["zh-TW", "zh-HK"],
        ]
        return ([language.code] + (regional[language.code] ?? [])).map { Locale.Language(identifier: $0) }
    }
}

// MARK: - Google (free web endpoint, no key)

struct GoogleTranslationService: TranslationService {
    var name: String { L("service.google") }
    let symbol = "globe"

    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        translationStream { continuation in
            let code = { (l: Language) in ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW"][l.code] ?? l.code }
            var url = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
            url.queryItems = [.init(name: "client", value: "gtx"), .init(name: "dt", value: "t"),
                              .init(name: "sl", value: code(source)), .init(name: "tl", value: code(target))]
            var request = URLRequest(url: url.url!, timeoutInterval: 15)
            request.httpMethod = "POST"  // keeps long text out of the URL
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [.init(name: "q", value: text)]
            request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [Any],
                  let segments = json.first as? [[Any]] else {
                throw TranslationFailure(errorDescription: L("error.googleUnavailable"))
            }
            continuation.yield(segments.compactMap { $0.first as? String }.joined())
        }
    }
}

// MARK: - LLM (any OpenAI-compatible endpoint: OpenAI, DeepSeek, Ollama, LM Studio…)

struct LLMConfig: Codable, Equatable {
    var enabled = false
    var name = L("service.llm.defaultName")
    var baseURL = "http://localhost:11434/v1"
    var model = "qwen3:4b"
    /// Sends `reasoning_effort: none` so thinking models answer immediately.
    var disableThinking = true

    struct Preset: Identifiable {
        let name: String, baseURL: String, model: String, disableThinking: Bool
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: L("service.llm.preset.ollama"), baseURL: "http://localhost:11434/v1", model: "qwen3:4b", disableThinking: true),
        Preset(name: L("service.llm.preset.lmStudio"), baseURL: "http://localhost:1234/v1", model: "local-model", disableThinking: true),
        Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1", model: "gpt-4.1-mini", disableThinking: false),
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat", disableThinking: false),
    ]

    init() {}

    // Tolerates configs saved by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LLMConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? d.baseURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        disableThinking = try c.decodeIfPresent(Bool.self, forKey: .disableThinking) ?? d.disableThinking
    }
}

struct LLMTranslationService: TranslationService {
    let config: LLMConfig
    let apiKey: String?
    var name: String { config.model.isEmpty ? config.name : config.model }
    let symbol = "sparkles"

    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        translationStream { continuation in
            let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            guard let url = URL(string: base + "/chat/completions") else {
                throw TranslationFailure(errorDescription: L("error.invalidEndpoint"), recovery: .openSettings)
            }
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
            var body: [String: Any] = [
                "model": config.model,
                "stream": true,
                "temperature": 0.2,
                "messages": [
                    ["role": "system", "content": """
                        You are a professional translator. Translate the user's text from \(source.englishName) \
                        into \(target.englishName). Keep the original line breaks, formatting, numbers and names. \
                        Output only the translation, without quotes, notes or explanations.
                        """],
                    ["role": "user", "content": text],
                ],
            ]
            if config.disableThinking { body["reasoning_effort"] = "none" }
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                var body = ""
                for try await line in bytes.lines { body += line; if body.count > 400 { break } }
                throw TranslationFailure(errorDescription: L("error.httpStatus", http.statusCode, Self.message(from: body)),
                                         recovery: .openSettings)
            }
            var output = ""
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let data = payload.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choice = (json["choices"] as? [[String: Any]])?.first,
                      let delta = choice["delta"] as? [String: Any],
                      let piece = delta["content"] as? String else { continue }
                output += piece
                continuation.yield(Self.stripThinking(output))
            }
            if Self.stripThinking(output).isEmpty {
                throw TranslationFailure(errorDescription: L("error.noTranslation"), recovery: .openSettings)
            }
        }
    }

    /// Model IDs offered by the endpoint (`GET /models`), e.g. the models installed in Ollama.
    static func models(config: LLMConfig, apiKey: String?) async throws -> [String] {
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let url = URL(string: base + "/models") else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 5)
        if let apiKey, !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        let (data, _) = try await URLSession.shared.data(for: request)
        let list = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]]
        return (list ?? []).compactMap { $0["id"] as? String }.sorted()
    }

    /// Reasoning models (e.g. DeepSeek-R1, Qwen3) may emit <think>…</think>; hide it. Some servers send a newline
    /// before the tag, and while streaming the tag itself can arrive in pieces ("<th", "ink>").
    static func stripThinking(_ s: String) -> String {
        let start = s.drop(while: \.isWhitespace)
        if start.isEmpty || "<think>".hasPrefix(start) { return "" }
        guard start.hasPrefix("<think>") else { return s }
        guard let end = s.range(of: "</think>") else { return "" }
        return String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return body.isEmpty ? L("error.requestFailed") : String(body.prefix(160))
    }
}
