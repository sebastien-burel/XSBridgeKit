import Foundation

/// Returns the full content of a saved memory (by id), or all of them when no
/// id is given.
public struct ReadMemoryTool: Tool {
    public let store: MemoryStoring

    public init(store: MemoryStoring) {
        self.store = store
    }

    public let spec = ToolSpec(
        name: "read_memory",
        description: """
        Reads saved long-term memories. Provide an id (from list_memories) to
        read one in full, or omit it to read them all. Read-only.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "The id of the memory to read. Omit to read all."
            }
          },
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let id: String?
    }

    public func execute(arguments: Data) async throws -> String {
        let args = (try? JSONDecoder().decode(Args.self, from: arguments)) ?? Args(id: nil)

        if let idString = args.id?.trimmingCharacters(in: .whitespaces), !idString.isEmpty {
            guard let id = UUID(uuidString: idString) else {
                throw ToolError.invalidArguments(reason: "id invalide : \(idString)")
            }
            guard let memory = await store.memory(id: id) else {
                throw ToolError.execution(message: "mémoire introuvable : \(idString)")
            }
            return "\(memory.title)\n\(memory.content)"
        }

        let memories = await store.memories
        guard !memories.isEmpty else { return "Aucune mémoire enregistrée." }
        return memories
            .map { "## \($0.title)\n\($0.content)" }
            .joined(separator: "\n\n")
    }
}
