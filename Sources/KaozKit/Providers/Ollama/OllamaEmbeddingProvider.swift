import Foundation

/// First conformer of `EmbeddingProvider`. Wraps `OllamaClient.embed` and
/// pins the model + dimension at construction time so the caller (Indexer)
/// can compare against `WikiSchemaV1.embeddingDimension` before writing.
public struct OllamaEmbeddingProvider: EmbeddingProvider {
    public let id: String = "ollama"
    public let baseURL: URL
    public let modelID: String
    public let dimension: Int

    private let client: OllamaClient

    public init(baseURL: URL, modelID: String, dimension: Int, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.modelID = modelID
        self.dimension = dimension
        self.client = OllamaClient(baseURL: baseURL, session: session)
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        try await client.embed(model: modelID, inputs: texts)
    }
}
