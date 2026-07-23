import Foundation

/// Lets the model persist a fact worth remembering across conversations.
public struct SaveMemoryTool: Tool {
    public let store: MemoryStoring

    public init(store: MemoryStoring) {
        self.store = store
    }

    public let spec = ToolSpec(
        name: "save_memory",
        description: """
        Pins a small, stable preference about the user so it's always in
        context: their name, preferred language, tone, how they like answers.
        NOT for knowledge or facts about a topic, a person, or a project —
        that goes in the wiki via write_wiki_page. Not for one-off chatter.
        Provide a short title and the content to remember.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "title": {
              "type": "string",
              "description": "Short label for the memory (a few words)."
            },
            "content": {
              "type": "string",
              "description": "The information to remember."
            }
          },
          "required": ["content"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let title: String?
        let content: String
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            let raw = String(data: arguments, encoding: .utf8) ?? "<binary>"
            throw ToolError.invalidArguments(
                reason: "expected {title?: string, content: string}, got: \(raw)"
            )
        }
        let content = args.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw ToolError.invalidArguments(reason: "content ne peut pas être vide")
        }

        let title = args.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false) ? title! : Self.deriveTitle(from: content)
        let memory = await store.add(title: resolvedTitle, content: content)
        return "Mémorisé : « \(memory.title) » (id \(memory.id.uuidString))."
    }

    /// Falls back to the first words of the content when no title is given.
    private static func deriveTitle(from content: String) -> String {
        let firstLine = content.split(separator: "\n").first.map(String.init) ?? content
        return String(firstLine.prefix(40))
    }
}
