import Foundation

public struct OllamaProvider: LLMProvider {
    public let id: String = "ollama"
    public let displayName: String = "Ollama"

    public let baseURL: URL
    public let model: String

    private let client: OllamaClient

    public init(baseURL: URL, model: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.client = OllamaClient(baseURL: baseURL, session: session)
    }

    public func availability() async -> ProviderAvailability {
        do {
            let models = try await client.listModels()
            guard !models.isEmpty else {
                return .unavailable(reason: "Le serveur ne propose aucun modèle.")
            }
            guard models.contains(where: { $0.name == model }) else {
                return .unavailable(reason: "Le modèle « \(model) » n'est pas installé sur ce serveur.")
            }
            return .ready
        } catch let error as OllamaClientError {
            return .unavailable(reason: error.errorDescription ?? "Erreur inconnue.")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        client.chat(model: model, messages: messages, tools: tools)
    }
}
