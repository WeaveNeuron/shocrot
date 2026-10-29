import Foundation
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
        if s.llm.enabled { services.append(LLMTranslationService(config: s.llm, apiKey: Keychain.llmAPIKey)) }
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
    let name = "Apple 翻译"
    let symbol = "apple.logo"

    func translate(_ text: String, from source: Language, to target: Language) -> AsyncThrowingStream<String, Error> {
        translationStream { continuation in
            switch await LanguageAvailability().status(from: source.locale, to: target.locale) {
            case .unsupported:
                throw TranslationFailure(errorDescription: "Apple 翻译暂不支持 \(source.name) → \(target.name)")
            case .supported:
                throw TranslationFailure(errorDescription: "需要先下载 \(source.name) 和 \(target.name) 的离线翻译语言",
                                         recovery: .downloadLanguages)
            case .installed:
                break
            @unknown default:
                break
            }
            let session = TranslationSession(installedSource: source.locale, target: target.locale)
            continuation.yield(try await session.translate(text).targetText)
        }
    }
}

// MARK: - Google (free web endpoint, no key)

struct GoogleTranslationService: TranslationService {
    let name = "Google 翻译"
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
                throw TranslationFailure(errorDescription: "Google 翻译暂时不可用，请检查网络")
            }
            continuation.yield(segments.compactMap { $0.first as? String }.joined())
        }
    }
}

// MARK: - LLM (any OpenAI-compatible endpoint: OpenAI, DeepSeek, Ollama, LM Studio…)

struct LLMConfig: Codable, Equatable {
    var enabled = false
    var name = "大模型"
    var baseURL = "http://localhost:11434/v1"
    var model = "qwen3:4b"
    /// Sends `reasoning_effort: none` so thinking models answer immediately.
    var disableThinking = true

    struct Preset: Identifiable {
        let name: String, baseURL: String, model: String, disableThinking: Bool
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Ollama（本地）", baseURL: "http://localhost:11434/v1", model: "qwen3:4b", disableThinking: true),
        Preset(name: "LM Studio（本地）", baseURL: "http://localhost:1234/v1", model: "local-model", disableThinking: true),
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
                throw TranslationFailure(errorDescription: "接口地址无效", recovery: .openSettings)
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
                throw TranslationFailure(errorDescription: "接口返回 \(http.statusCode)：\(Self.message(from: body))",
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
                throw TranslationFailure(errorDescription: "模型没有返回译文，可尝试开启“关闭思考”或更换模型", recovery: .openSettings)
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

    /// Reasoning models (e.g. DeepSeek-R1, Qwen3) may emit <think>…</think>; hide it.
    private static func stripThinking(_ s: String) -> String {
        guard s.hasPrefix("<think>") else { return s }
        guard let end = s.range(of: "</think>") else { return "" }
        return String(s[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func message(from body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        return body.isEmpty ? "请求失败" : String(body.prefix(160))
    }
}
