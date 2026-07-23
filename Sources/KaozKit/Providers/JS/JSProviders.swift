import Foundation

/// Factories for the JS-authored providers. Each provider is a bundled ES module
/// (`Resources/js/<name>.js`) whose default export is `{ chat(request, onEvent) }`
/// and which pulls in the native `XMLHttpRequest` shim. Config
/// (`apiKey`/`model`/`baseURL`) is passed per request via `request.config`.
public enum JSProviders {

    // A JSProvider owns an XS engine, so creating one per SwiftUI render (as a
    // provider factory called in `body` does) would spin up a machine on every
    // token. Cache instances by their config so repeated builds reuse the same
    // engine; the per-request payload (messages/tools) is passed at chat time,
    // not baked into the engine.
    private static let cacheLock = NSLock()
    private static var cache: [String: JSProvider] = [:]

    private static func cached(
        id: String, displayName: String, providerModule: String, config: [String: Any]
    ) -> JSProvider? {
        let key = [id,
                   (config["apiKey"] as? String) ?? "",
                   (config["model"] as? String) ?? "",
                   (config["baseURL"] as? String) ?? ""].joined(separator: "\u{1}")
        cacheLock.lock()
        defer { cacheLock.unlock() }
        // Always reuse the cached instance. A provider factory is called per
        // SwiftUI render (including per streamed token, while a chat is in
        // flight): returning a fresh instance then would spin up a new XS engine
        // on every token. Re-renders only pass the provider around; the actual
        // chat() (sequential) is guarded separately, and a cancelled stream
        // self-heals via onTermination.
        if let existing = cache[key] { return existing }
        guard let provider = JSProvider(
            id: id, displayName: displayName, providerModule: providerModule, config: config)
        else { return nil }
        cache[key] = provider
        return provider
    }

    /// Anthropic Messages API, written in JavaScript (the JS-first counterpart
    /// of the Swift `AnthropicProvider`). `baseURL` overrides the endpoint (for
    /// tests / proxies); defaults to https://api.anthropic.com.
    public static func anthropic(apiKey: String, model: String, baseURL: String? = nil) -> JSProvider? {
        var config: [String: Any] = ["apiKey": apiKey, "model": model]
        if let baseURL { config["baseURL"] = baseURL }
        return cached(
            id: "anthropic-js", displayName: "Anthropic (JS)",
            providerModule: "anthropic", config: config)
    }

    /// OpenAI Chat Completions API, written in JavaScript. `baseURL` overrides
    /// the endpoint host (default https://api.openai.com/v1); the path
    /// `/chat/completions` is appended.
    public static func openai(apiKey: String, model: String, baseURL: String? = nil) -> JSProvider? {
        var config: [String: Any] = ["apiKey": apiKey, "model": model]
        if let baseURL { config["baseURL"] = baseURL }
        return cached(
            id: "openai-js", displayName: "OpenAI (JS)",
            providerModule: "openai", config: config)
    }

    /// Any OpenAI-compatible Chat Completions endpoint, in JavaScript (Mistral,
    /// DeepSeek, Qwen, Z.AI, local servers…). `baseURL` must include the API
    /// version path (e.g. `https://api.mistral.ai/v1`); `/chat/completions` is
    /// appended.
    public static func openaiCompatible(
        id: String, displayName: String, apiKey: String, model: String, baseURL: String
    ) -> JSProvider? {
        cached(
            id: id, displayName: displayName, providerModule: "openai",
            config: ["apiKey": apiKey, "model": model, "baseURL": baseURL])
    }

    /// Ollama's `/api/chat` (NDJSON stream, no auth) in JavaScript. `baseURL`
    /// is the server root (e.g. http://localhost:11434); `/api/chat` is appended.
    public static func ollama(model: String, baseURL: String) -> JSProvider? {
        cached(
            id: "ollama-js", displayName: "Ollama (JS)", providerModule: "ollama",
            config: ["apiKey": "", "model": model, "baseURL": baseURL])
    }

    /// Kimi K3 (Moonshot AI) — OpenAI-compatible Chat Completions, so it reuses
    /// the `openai` module. Default endpoint https://api.moonshot.ai/v1; the
    /// stream carries both `content` and `reasoning_content` deltas.
    public static func kimi(apiKey: String, model: String = "kimi-k3", baseURL: String? = nil) -> JSProvider? {
        openaiCompatible(
            id: "kimi-js", displayName: "Kimi (JS)", apiKey: apiKey, model: model,
            baseURL: baseURL ?? "https://api.moonshot.ai/v1")
    }

    /// Google Gemini's `:streamGenerateContent?alt=sse` in JavaScript. `baseURL`
    /// defaults to the v1beta endpoint. The API key goes in `x-goog-api-key`.
    public static func google(apiKey: String, model: String, baseURL: String? = nil) -> JSProvider? {
        var config: [String: Any] = ["apiKey": apiKey, "model": model]
        if let baseURL { config["baseURL"] = baseURL }
        return cached(
            id: "google-js", displayName: "Google (JS)",
            providerModule: "google", config: config)
    }
}
