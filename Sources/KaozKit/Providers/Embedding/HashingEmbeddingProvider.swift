import Foundation

/// A dependency-free embedding: a hashed bag-of-words (feature hashing), L2-
/// normalized. It captures **lexical** similarity (shared words) — enough to
/// make memory search useful everywhere with no model or network, and the
/// deterministic default for headless runs. For true **semantic** similarity
/// (synonyms, paraphrase), plug in a model-backed `EmbeddingProvider`
/// (MLX / Ollama) instead — the retrieval machinery is identical.
public struct HashingEmbeddingProvider: EmbeddingProvider {
    public let id = "hashing"
    public let modelID: String
    public let dimension: Int

    public init(dimension: Int = 256) {
        self.dimension = dimension
        self.modelID = "hashing-\(dimension)"
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { vector(for: $0) }
    }

    private func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for token in Self.tokenize(text) {
            let h = Self.hash(token)
            let bucket = Int(h % UInt64(dimension))
            // A sign bit off another hash bit reduces collisions cancelling out.
            v[bucket] += (h & 0x8000_0000) != 0 ? 1 : -1
        }
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        if norm > 0 { for i in v.indices { v[i] /= norm } }
        return v
    }

    /// Lowercased alphanumeric word tokens.
    static func tokenize(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// FNV-1a — stable across runs (unlike Swift's randomized Hasher).
    static func hash(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in s.utf8 {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        return h
    }
}
