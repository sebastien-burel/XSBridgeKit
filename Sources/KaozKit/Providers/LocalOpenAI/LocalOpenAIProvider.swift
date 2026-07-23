import Foundation

/// Generic OpenAI-compatible provider for self-hosted inference servers:
/// vLLM, LM Studio, llama.cpp's `server`, etc. The user supplies the
/// base URL (and optionally an API key) in the settings panel; the
/// model list comes from `/v1/models` like any cloud OpenAI host.
public struct LocalOpenAIProvider: LLMProvider {
    public let id: String = "localOpenAI"
    public let displayName: String = "Compatible OpenAI"

    public let baseURL: URL
    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public init(baseURL: URL, apiKey: String, model: String, session: URLSession = .shared) {
        // Cloud providers we wrap with OpenAICompatibleClient bake the
        // `/v1` (or `/v4`) prefix into a static base URL. Local servers
        // (vLLM, LM Studio, llama.cpp) speak the standard `/v1/*`
        // endpoints, but users type just `http://host:port` in
        // settings — so we append `/v1` when it isn't already there.
        let normalized = Self.normalize(baseURL)
        self.baseURL = normalized
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: normalized, apiKey: apiKey, session: session)
    }

    /// Adds `/v1` when the path doesn't already end in `/v<digits>`.
    /// Pure function so the settings UI can show the user the real
    /// URL their queries will hit.
    public static func normalize(_ url: URL) -> URL {
        let path = url.path
        let regex = /\/v\d+\/?$/
        if path.contains(regex) { return url }
        return url.appending(path: "/v1")
    }

    public func availability() async -> ProviderAvailability {
        // No key required for most local servers (vLLM/LM Studio/llama.cpp
        // default to no auth). Reachability check below catches a typo
        // in the URL.
        do {
            let models = try await client.listModels()
            guard models.contains(where: { $0.id == model }) else {
                return .unavailable(
                    reason: "Le modèle « \(model) » n'est pas servi par ce serveur."
                )
            }
            return .ready
        } catch let error as OpenAICompatibleError {
            return .unavailable(reason: error.errorDescription ?? "Erreur.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools)
    }
}
