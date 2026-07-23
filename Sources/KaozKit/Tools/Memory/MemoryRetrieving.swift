import Foundation

/// A memory plus its relevance score for a query (higher = more relevant).
public struct ScoredMemory: Sendable, Hashable {
    public let memory: Memory
    public let score: Float
    public init(memory: Memory, score: Float) {
        self.memory = memory
        self.score = score
    }
}

/// Semantic retrieval over the memory store — separate from `MemoryStoring`
/// (which is list/get only) so that adding search doesn't force every conformer
/// (e.g. the app's `MemoryStore`) to implement it. A store that supports it
/// conforms to both; `host.memory.search(query)` uses it when available.
@MainActor
public protocol MemoryRetrieving: AnyObject, Sendable {
    /// Return up to `limit` memories most relevant to `query`, best first.
    func search(_ query: String, limit: Int) async -> [ScoredMemory]
}
