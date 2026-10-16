import Foundation

/// Where the assistant's brain runs. Anthropic uses the native Messages API;
/// everything else speaks the OpenAI chat-completions format.
struct Provider: Identifiable {
    let id: String
    let name: String
    let baseURL: String          // OpenAI-compatible base, e.g. https://api.openai.com/v1
    let keyAccount: String       // Keychain account
    let keyHint: String
    let consoleURL: String
    let defaultModel: String
    /// Fast model for dictation cleanup (empty = use the main model).
    let fastModel: String
    /// Newer OpenAI models reject `max_tokens`; they want `max_completion_tokens`.
    let usesMaxCompletionTokens: Bool

    var isAnthropic: Bool { id == "anthropic" }

    static let all: [Provider] = [
        Provider(id: "anthropic", name: "Anthropic (Claude)", baseURL: "https://api.anthropic.com/v1",
                 keyAccount: "anthropic_api_key", keyHint: "sk-ant-…", consoleURL: "console.anthropic.com",
                 defaultModel: "claude-sonnet-5-5", fastModel: "claude-haiku-5-5", usesMaxCompletionTokens: false),
        Provider(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
                 keyAccount: "openai_api_key", keyHint: "sk-…", consoleURL: "platform.openai.com",
                 defaultModel: "chat-latest", fastModel: "", usesMaxCompletionTokens: true),
        Provider(id: "groq", name: "Groq", baseURL: "https://api.groq.com/openai/v1",
                 keyAccount: "groq_api_key", keyHint: "gsk_…", consoleURL: "console.groq.com",
                 defaultModel: "openai/gpt-oss-120b", fastModel: "llama-3.1-8b-instant", usesMaxCompletionTokens: false),
        Provider(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1",
                 keyAccount: "openrouter_api_key", keyHint: "sk-or-…", consoleURL: "openrouter.ai",
                 defaultModel: "anthropic/claude-sonnet-5.5", fastModel: "", usesMaxCompletionTokens: false),
        Provider(id: "custom", name: "Custom (OpenAI-compatible)", baseURL: "",
                 keyAccount: "custom_api_key", keyHint: "API key", consoleURL: "",
                 defaultModel: "", fastModel: "", usesMaxCompletionTokens: false),
    ]

    static func named(_ id: String) -> Provider {
        all.first { $0.id == id } ?? all[0]
    }

    func key() -> String? {
        if let k = Keychain.read(keyAccount), !k.isEmpty { return k }
        let env: String
        switch id {
        case "anthropic": env = "ANTHROPIC_API_KEY"
        case "openai": env = "OPENAI_API_KEY"
        case "groq": env = "GROQ_API_KEY"
        case "openrouter": env = "OPENROUTER_API_KEY"
        default: env = "OPENAI_COMPAT_API_KEY"
        }
        if let v = ProcessInfo.processInfo.environment[env], !v.isEmpty { return v }
        return nil
    }

    func resolvedBaseURL(custom: String) -> URL? {
        var s = id == "custom" ? custom : baseURL
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }
}

/// Live model lists, fetched from each provider's /models endpoint and cached for the session.
@MainActor
final class ModelCatalog {
    static let shared = ModelCatalog()
    private(set) var models: [String: [String]] = [:]
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    var onChange: (() -> Void)?

    func list(for provider: Provider) -> [String] { models[provider.id] ?? [] }

    func refresh(_ provider: Provider, customBaseURL: String) {
        guard !loading.contains(provider.id), let key = provider.key() else { return }
        guard let base = provider.resolvedBaseURL(custom: customBaseURL) else { return }
        loading.insert(provider.id)
        errors[provider.id] = nil
        onChange?()
        Task {
            do {
                let ids = try await Self.fetch(provider: provider, base: base, key: key)
                self.models[provider.id] = ids
            } catch {
                self.errors[provider.id] = error.localizedDescription
            }
            self.loading.remove(provider.id)
            self.onChange?()
        }
    }

    private static func fetch(provider: Provider, base: URL, key: String) async throws -> [String] {
        var req = URLRequest(url: base.appendingPathComponent("models"), timeoutInterval: 20)
        if provider.isAnthropic {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        } else {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw SimpleError("Couldn't list models (HTTP \(status)). Check the API key.")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let items = json["data"] as? [[String: Any]] ?? []
        var ids = items.compactMap { $0["id"] as? String }
        ids = ids.filter { Self.isChatModel($0, provider: provider) }
        if provider.id == "openrouter" {
            let prefixes = ["anthropic/", "openai/", "google/", "meta-llama/", "deepseek/", "x-ai/", "mistralai/", "qwen/"]
            ids = ids.filter { id in prefixes.contains { id.hasPrefix($0) } && !id.contains(":free") }
        }
        if provider.isAnthropic {
            // Newest first, as Anthropic returns them; others alphabetical.
            return ids
        }
        return ids.sorted()
    }

    private static func isChatModel(_ id: String, provider: Provider) -> Bool {
        let l = id.lowercased()
        let excluded = ["whisper", "tts", "embedding", "embed", "moderation", "realtime", "audio", "image",
                        "transcribe", "guard", "playai", "dall-e", "sora", "live", "search-preview",
                        "compound", "safeguard", "rerank", "vision-instruct"]
        if excluded.contains(where: { l.contains($0) }) { return false }
        if provider.id == "openai" {
            // Keep the GPT / o-series chat models; skip dated snapshots to keep the menu short.
            let dated = l.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
            return (l.hasPrefix("gpt") || l.hasPrefix("o1") || l.hasPrefix("o3") || l.hasPrefix("o4") || l.hasPrefix("chat")) && !dated
        }
        return true
    }
}
