import Foundation

public struct MistralProvider: LLMProvider {
    public let id: String = "mistral"
    public let displayName: String = "Mistral"

    public let apiKey: String
    public let model: String

    private let client: OpenAICompatibleClient

    public static let baseURL = URL(string: "https://api.mistral.ai/v1")!

    public init(apiKey: String, model: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.client = OpenAICompatibleClient(baseURL: Self.baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard !apiKey.isEmpty else {
            return .unavailable(reason: "Renseignez votre clé API Mistral dans les réglages.")
        }
        do {
            let models = try await client.listModels()
            guard models.contains(where: { $0.id == model }) else {
                return .unavailable(reason: "Le modèle « \(model) » n'est pas accessible avec cette clé.")
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
