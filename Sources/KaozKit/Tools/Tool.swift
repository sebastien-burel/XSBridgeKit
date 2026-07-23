import Foundation

/// Describes a tool: the metadata an LLM needs to decide to call it, and how
/// the app exposes the schema in its API requests. `inputSchemaJSON` is kept
/// as raw JSON text so each provider can splice it verbatim into its tool
/// definition payload — providers disagree about minor schema conventions,
/// passing through avoids re-encoding bugs.
public struct ToolSpec: Hashable, Sendable {
    public let name: String
    public let description: String
    public let inputSchemaJSON: String

    public init(name: String, description: String, inputSchemaJSON: String) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// One invocation produced by the LLM. The id is provider-assigned and used
/// to correlate the result back to the same call in multi-turn / parallel
/// tool use. `arguments` is the raw JSON body the LLM emitted — each tool
/// decodes into its own typed argument struct.
public struct ToolCall: Hashable, Sendable {
    public let id: String
    public let toolName: String
    public let arguments: Data

    public init(id: String, toolName: String, arguments: Data) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
    }
}

/// The serialised result of a tool execution. Always a string because every
/// provider's tool-result protocol consumes strings. If a tool wants to
/// return structured data, it serialises to JSON itself.
public struct ToolResult: Hashable, Sendable {
    public let callID: String
    public let content: String
    public let isError: Bool

    public init(callID: String, content: String, isError: Bool) {
        self.callID = callID
        self.content = content
        self.isError = isError
    }
}

public enum ToolError: Error, LocalizedError, Equatable {
    case invalidArguments(reason: String)
    case execution(message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidArguments(let reason): return "Arguments invalides : \(reason)"
        case .execution(let message):       return message
        }
    }
}

public protocol Tool: Sendable {
    var spec: ToolSpec { get }
    func execute(arguments: Data) async throws -> String
}
