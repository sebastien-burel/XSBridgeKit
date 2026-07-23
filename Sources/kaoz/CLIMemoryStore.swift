import Foundation
import KaozKit

/// A plain file-backed `MemoryStoring` for the headless CLI — the non-bookmark,
/// non-Observable counterpart of the app's `MemoryStore`. Persists the memories
/// as a JSON array; a missing/unreadable file starts empty.
@MainActor
final class CLIMemoryStore: MemoryStoring {
    private(set) var memories: [Memory] = []
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        load()
    }

    @discardableResult
    func add(title: String, content: String) -> Memory {
        let memory = Memory(title: title, content: content)
        memories.append(memory)
        save()
        return memory
    }

    func delete(id: UUID) {
        memories.removeAll { $0.id == id }
        save()
    }

    func memory(id: UUID) -> Memory? {
        memories.first { $0.id == id }
    }

    // MARK: - Persistence

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(memories) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([Memory].self, from: data)
        else { return }
        memories = decoded.sorted { $0.createdAt < $1.createdAt }
    }
}
