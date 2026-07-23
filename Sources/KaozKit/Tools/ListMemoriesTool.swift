import Foundation

/// Lists the saved memories so the model can pick one to read in full.
public struct ListMemoriesTool: Tool {
    public let store: MemoryStoring

    public init(store: MemoryStoring) {
        self.store = store
    }

    public let spec = ToolSpec(
        name: "list_memories",
        description: """
        Lists the saved long-term memories as "id<TAB>title". Use read_memory
        with an id to get the full content of one. Read-only.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {},
          "additionalProperties": false
        }
        """
    )

    public func execute(arguments: Data) async throws -> String {
        let memories = await store.memories
        guard !memories.isEmpty else { return "Aucune mémoire enregistrée." }
        return memories
            .map { "\($0.id.uuidString)\t\($0.title)" }
            .joined(separator: "\n")
    }
}
