import Foundation

/// A file-backed memory store with **semantic search**: it keeps the durable
/// notes (like a plain store) plus their embedding vectors, and `search(query)`
/// ranks them by cosine similarity to the query's embedding. Embeddings are
/// computed lazily (on first search) and persisted alongside the notes, so a
/// resident agent doesn't re-embed on every restart. The embedder is injected
/// (`HashingEmbeddingProvider` by default — lexical, zero-dep; a model-backed
/// one for true semantic).
@MainActor
public final class SemanticMemoryStore: MemoryStoring, MemoryRetrieving {

    private struct Entry: Codable {
        var memory: Memory
        var vector: [Float]?
    }
    private struct Persisted: Codable {
        var modelID: String
        var entries: [Entry]
    }

    private let fileURL: URL
    private let embedder: any EmbeddingProvider
    private var entries: [Entry] = []

    public init(fileURL: URL, embedder: any EmbeddingProvider) {
        self.fileURL = fileURL
        self.embedder = embedder
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        load()
    }

    // MARK: - MemoryStoring

    public var memories: [Memory] { entries.map(\.memory) }

    @discardableResult
    public func add(title: String, content: String) -> Memory {
        let memory = Memory(title: title, content: content)
        entries.append(Entry(memory: memory, vector: nil))   // embedded lazily on search
        save()
        return memory
    }

    public func delete(id: UUID) {
        entries.removeAll { $0.memory.id == id }
        save()
    }

    public func memory(id: UUID) -> Memory? {
        entries.first { $0.memory.id == id }?.memory
    }

    // MARK: - MemoryRetrieving

    public func search(_ query: String, limit: Int) async -> [ScoredMemory] {
        guard !entries.isEmpty, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        await ensureEmbeddings()
        guard let q = try? await embedder.embed([query]).first else { return [] }
        let scored = entries.compactMap { entry -> ScoredMemory? in
            guard let v = entry.vector else { return nil }
            return ScoredMemory(memory: entry.memory, score: Self.cosine(q, v))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(max(0, limit)))
    }

    // MARK: - Embedding

    /// Embed any entries that don't have a vector yet (batched), then persist.
    private func ensureEmbeddings() async {
        let missing = entries.indices.filter { entries[$0].vector == nil }
        guard !missing.isEmpty else { return }
        let texts = missing.map { Self.text(for: entries[$0].memory) }
        guard let vectors = try? await embedder.embed(texts), vectors.count == missing.count else { return }
        for (offset, idx) in missing.enumerated() { entries[idx].vector = vectors[offset] }
        save()
    }

    private static func text(for m: Memory) -> String {
        m.title.isEmpty ? m.content : "\(m.title)\n\(m.content)"
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        let payload = Persisted(modelID: embedder.modelID, entries: entries)
        if let data = try? encoder.encode(payload) { try? data.write(to: fileURL) }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let p = try? decoder.decode(Persisted.self, from: data) {
            // A different embedding model invalidates the vectors (different space).
            entries = p.modelID == embedder.modelID
                ? p.entries
                : p.entries.map { Entry(memory: $0.memory, vector: nil) }
        } else if let plain = try? decoder.decode([Memory].self, from: data) {
            // Migrate a plain memories.json (e.g. from CLIMemoryStore).
            entries = plain.map { Entry(memory: $0, vector: nil) }
        }
    }
}
