import Foundation
import MLX
import MLXEmbedders
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

/// Single owner of the loaded `EmbedderModelContainer` for one MLX
/// model. Serializes inference: MLX runs on a single Metal command
/// queue per process, so overlapping forward passes don't actually
/// parallelize and risk interleaving activations.
///
/// Lazy: the container is loaded on the first `embed()` call. If the
/// model isn't on disk yet, `MLXModelStore` downloads it first.
/// Subsequent calls reuse the warm container.
public actor MLXEmbeddingActor {
    /// One actor per `modelID` — switching models means a new actor
    /// (the old container is dropped, GPU memory reclaimed).
    private static var instances: [String: MLXEmbeddingActor] = [:]

    /// Returns the shared actor for `modelID`, creating it on first
    /// access. Thread-safe via the global actor isolation of static
    /// state (statics initialise once on first access; we only write
    /// behind the `Task { @MainActor }` boundary below if needed).
    @MainActor
    static public func shared(for modelID: String) -> MLXEmbeddingActor {
        if let existing = instances[modelID] { return existing }
        let actor = MLXEmbeddingActor(modelID: modelID)
        instances[modelID] = actor
        return actor
    }

    public let modelID: String

    /// Loaded container — `nil` until the first `embed()` call.
    /// Held outside any isolation since the actor itself is the
    /// isolation boundary.
    private var container: EmbedderModelContainer?

    /// Macro-produced downloader + tokenizer loader, mirrors the
    /// ones in `MLXModelStore`. We could share via a global but
    /// per-actor copies are cheap and keep this self-contained.
    private let downloader: any Downloader
    private let tokenizerLoader: any TokenizerLoader

    private init(modelID: String) {
        self.modelID = modelID
        self.downloader = #hubDownloader()
        self.tokenizerLoader = #huggingFaceTokenizerLoader()
    }

    // MARK: - Public

    /// Embeds a batch of texts. First call may take a few seconds
    /// (download + load); subsequent calls run a single Metal
    /// forward pass.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let container = try await loadIfNeeded()
        return await runForward(texts: texts, on: container)
    }

    /// Drops the loaded container, reclaiming its GPU memory. The next
    /// `embed()` reloads lazily. Mirrors `MLXChatActor.unload()`.
    public func unload() {
        container = nil
    }

    /// Unloads every loaded embedder container — the manual "décharger"
    /// command. Pair with `MLX.GPU.clearCache()` to return freed memory
    /// to the system.
    @MainActor
    static public func unloadAll() async {
        for actor in instances.values { await actor.unload() }
    }

    // MARK: - Internals

    private func loadIfNeeded() async throws -> EmbedderModelContainer {
        if let container { return container }
        // Make sure the model is on disk first — the factory will
        // also download if missing, but going through MLXModelStore
        // gives us our disk-space pre-flight + presence checks.
        _ = try await MLXModelStore.shared.download(modelID: modelID)

        let revision = await ModelCatalogService.shared.entry(forID: modelID)?.revision ?? "main"
        let loaded = try await EmbedderModelFactory.shared.loadContainer(
            from: downloader,
            using: tokenizerLoader,
            configuration: ModelConfiguration(id: modelID, revision: revision)
        ) { _ in
            // No progress reporting needed at load-time — the
            // download (above) already reported, and the actual
            // load is fast (memory mapping the safetensors).
        }
        container = loaded
        // Bump the mtime so the LRU eviction pass on next launch
        // treats this model as "recently used".
        await MLXModelStore.shared.touch(modelID: modelID)
        return loaded
    }

    private func runForward(texts: [String], on container: EmbedderModelContainer) async -> [[Float]] {
        await container.perform { (context: EmbedderModelContext) -> [[Float]] in
            let tokenizer = context.tokenizer
            let model = context.model
            let pooling = context.pooling

            // Tokenize each input with special tokens (CLS/SEP for
            // BERT-family, BOS/EOS for XLM-RoBERTa-family like
            // bge-m3).
            let inputs = texts.map { tokenizer.encode(text: $0, addSpecialTokens: true) }

            // Pad to the longest input. Use the eos id (or 0 as
            // fallback) so the attention mask we derive from
            // `!= padId` lights up the right positions.
            let padId = tokenizer.eosTokenId ?? 0
            let maxLen = max(inputs.map(\.count).max() ?? 0, 1)
            let padded = stacked(
                inputs.map { tokens -> MLXArray in
                    MLXArray(tokens + Array(repeating: padId, count: maxLen - tokens.count))
                }
            )

            let mask = (padded .!= padId)
            let tokenTypes = MLXArray.zeros(like: padded)

            // BERT/RoBERTa-style forward + mean/CLS pooling (decided
            // by the model config baked into `pooling`). Normalising
            // here means the indexer can use plain dot-product as
            // cosine similarity downstream.
            let result = pooling(
                model(padded, positionIds: nil, tokenTypeIds: tokenTypes, attentionMask: mask),
                normalize: true,
                applyLayerNorm: true
            )
            result.eval()
            return result.map { $0.asArray(Float.self) }
        }
    }
}
