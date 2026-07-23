import Foundation
import KaozKit

/// `LLMProvider` running a chat model in-process on Apple Silicon
/// via MLX-Swift. Mirrors `MLXEmbeddingProvider`'s shape: cheap +
/// stateless on its own, delegates the heavy lifting to a
/// per-model `MLXChatActor`.
public struct MLXLLMProvider: LLMProvider {
    public let id: String = "mlx"
    public let displayName: String = "Sur ce Mac"
    public let modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }

    public func availability() async -> ProviderAvailability {
        // The chat path will trigger a download on first call if
        // the model isn't on disk. We don't probe here — the
        // ModelStore + actor surface their own progress + errors,
        // and a precheck would either lie (network not the same
        // as on-disk) or duplicate work.
        if await MLXModelStore.shared.isInstalled(modelID: modelID) {
            return .ready
        }
        return .unavailable(reason: """
        Modèle « \(modelID) » pas encore téléchargé. Va dans \
        Réglages → Sur ce Mac → bouton « Télécharger ».
        """)
    }

    public func chat(
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let actor = await MLXChatActor.shared(for: modelID)
                do {
                    for try await event in await actor.chat(messages: messages, tools: tools) {
                        if Task.isCancelled { break }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
