import Foundation
import KaozKit

/// `EmbeddingProvider` running bge-m3 (and friends) in-process on
/// Apple Silicon via MLX-Swift. Phase A3: delegates to
/// `MLXEmbeddingActor` which holds the loaded container and
/// serializes forward passes (MLX = single Metal command queue).
///
/// The provider itself is cheap and stateless — all heavy lifting
/// (download + load + inference) lives in the actor.
public struct MLXEmbeddingProvider: EmbeddingProvider {
    public let id: String = "mlx"
    public let modelID: String
    public let dimension: Int

    public init(modelID: String, dimension: Int) {
        self.modelID = modelID
        self.dimension = dimension
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let actor = await MLXEmbeddingActor.shared(for: modelID)
        return try await actor.embed(texts)
    }
}
