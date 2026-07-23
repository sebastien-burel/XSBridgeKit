import Foundation
import FoundationModels

public struct AppleIntelligenceProvider: LLMProvider {
    public let id: String = "apple"
    public let displayName: String = "Apple Intelligence"

    /// Foundation Models invokes tools *inside* `streamResponse` (the session
    /// runs each `call` and keeps generating), unlike our other providers
    /// where ChatSession drives the loop. We therefore need the executable
    /// tools here, not just their specs.
    let toolRegistry: ToolRegistry

    public init(toolRegistry: ToolRegistry = ToolRegistry(tools: [])) {
        self.toolRegistry = toolRegistry
    }

    /// Synchronous convenience for UI hints (e.g. sidebar indicator).
    /// The full `availability()` returns the precise reason of unavailability.
    public static var isReady: Bool {
        SystemLanguageModel.default.isAvailable
    }

    public func availability() async -> ProviderAvailability {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .ready
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "Cet appareil ne prend pas en charge Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Activez Apple Intelligence dans les Réglages système.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "Le modèle Apple Intelligence se télécharge ou n'est pas prêt.")
        case .unavailable(let other):
            return .unavailable(reason: "Indisponible : \(other).")
        }
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let lastUserIdx = messages.lastIndex(where: { $0.role == .user }) else {
                        throw AppleIntelligenceError.noUserMessage
                    }
                    let priorHistory = Array(messages[..<lastUserIdx])
                    let lastUser = messages[lastUserIdx]

                    let transcript = Self.buildTranscript(
                        systemPrompt: Self.defaultInstructions,
                        history: priorHistory
                    )
                    let bridged = Self.bridgeTools(tools, registry: toolRegistry)
                    let session = LanguageModelSession(
                        tools: bridged,
                        transcript: transcript
                    )

                    var emitted = 0
                    let stream = session.streamResponse(to: lastUser.content)
                    for try await snapshot in stream {
                        if Task.isCancelled { break }
                        let text = snapshot.content
                        if text.count > emitted {
                            let startIndex = text.index(text.startIndex, offsetBy: emitted)
                            let delta = String(text[startIndex...])
                            emitted = text.count
                            continuation.yield(.textDelta(delta))
                        }
                    }
                    continuation.finish()
                } catch let generation as LanguageModelSession.GenerationError {
                    continuation.finish(
                        throwing: AppleIntelligenceError.generation(Self.describe(generation))
                    )
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Transcript construction

    private static let defaultInstructions =
        "Tu es un assistant utile. Réponds clairement et en français par défaut."

    private static func buildTranscript(
        systemPrompt: String,
        history: [ChatMessage]
    ) -> Transcript {
        var entries: [Transcript.Entry] = []

        entries.append(.instructions(
            Transcript.Instructions(
                id: UUID().uuidString,
                segments: [.text(textSegment(systemPrompt))],
                toolDefinitions: []
            )
        ))

        for message in history {
            let segment: Transcript.Segment = .text(textSegment(message.content))
            switch message.role {
            case .user:
                entries.append(.prompt(
                    Transcript.Prompt(
                        id: UUID().uuidString,
                        segments: [segment],
                        options: GenerationOptions(),
                        responseFormat: nil
                    )
                ))
            case .assistant:
                entries.append(.response(
                    Transcript.Response(
                        id: UUID().uuidString,
                        assetIDs: [],
                        segments: [segment]
                    )
                ))
            case .system:
                entries.append(.instructions(
                    Transcript.Instructions(
                        id: UUID().uuidString,
                        segments: [segment],
                        toolDefinitions: []
                    )
                ))
            case .toolCall, .toolResult:
                // Foundation Models has its own Tool protocol — Bloc 4c will
                // bridge our ToolCall/ToolResult into Transcript.toolCalls /
                // .toolOutput entries. For now we drop them.
                continue
            }
        }

        return Transcript(entries: entries)
    }

    private static func textSegment(_ content: String) -> Transcript.TextSegment {
        Transcript.TextSegment(id: UUID().uuidString, content: content)
    }

    /// Foundation Models surfaces opaque `error -1` descriptions; pull the
    /// human-readable parts so the failure banner says something actionable.
    /// `errorDescription` and `failureReason` often carry the same string
    /// (e.g. "Exceeded model context window size" appears on both), so we
    /// dedupe while preserving order to avoid showing it twice.
    private static func describe(_ error: LanguageModelSession.GenerationError) -> String {
        let candidates = [error.errorDescription, error.failureReason, error.recoverySuggestion]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        var seen: Set<String> = []
        let parts = candidates.filter { seen.insert($0).inserted }
        return parts.isEmpty ? String(describing: error) : parts.joined(separator: " ")
    }

    // MARK: - Tool bridging

    /// Wraps the requested specs (whose implementations live in `registry`)
    /// as Foundation Models tools. Specs missing from the registry or whose
    /// schema can't be translated are skipped.
    private static func bridgeTools(
        _ specs: [ToolSpec],
        registry: ToolRegistry
    ) -> [any FoundationModels.Tool] {
        specs.compactMap { spec in
            guard registry.tool(named: spec.name) != nil,
                  let schema = try? generationSchema(for: spec) else { return nil }
            return BridgedTool(
                name: spec.name,
                description: spec.description,
                parameters: schema
            ) { data in
                let result = await registry.execute(
                    ToolCall(id: UUID().uuidString, toolName: spec.name, arguments: data)
                )
                return result.content
            }
        }
    }

    /// Translates the subset of JSON Schema our tools use (object of scalar
    /// properties, optional enums, `required`) into a Foundation Models
    /// `GenerationSchema` via `DynamicGenerationSchema`.
    static func generationSchema(for spec: ToolSpec) throws -> GenerationSchema {
        let object = (try? JSONSerialization.jsonObject(with: Data(spec.inputSchemaJSON.utf8)))
            as? [String: Any] ?? [:]
        let properties = object["properties"] as? [String: Any] ?? [:]
        let required = Set(object["required"] as? [String] ?? [])

        let props: [DynamicGenerationSchema.Property] = properties.compactMap { name, raw in
            guard let prop = raw as? [String: Any] else { return nil }
            return DynamicGenerationSchema.Property(
                name: name,
                description: prop["description"] as? String,
                schema: leafSchema(for: prop, name: name),
                isOptional: !required.contains(name)
            )
        }

        let root = DynamicGenerationSchema(
            name: spec.name,
            description: spec.description,
            properties: props
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func leafSchema(
        for prop: [String: Any],
        name: String
    ) -> DynamicGenerationSchema {
        if let values = prop["enum"] as? [String] {
            return DynamicGenerationSchema(name: name, anyOf: values)
        }
        switch prop["type"] as? String {
        case "integer": return DynamicGenerationSchema(type: Int.self)
        case "number":  return DynamicGenerationSchema(type: Double.self)
        case "boolean": return DynamicGenerationSchema(type: Bool.self)
        default:        return DynamicGenerationSchema(type: String.self)
        }
    }
}

/// Adapts one of our registry tools to the Foundation Models `Tool` protocol.
/// Arguments arrive as dynamic `GeneratedContent`; we hand their JSON straight
/// to the underlying tool. Execution goes through `ToolRegistry.execute`, so
/// errors come back as result text the model can reason about rather than
/// throwing.
private struct BridgedTool: FoundationModels.Tool {
    let name: String
    let description: String
    let parameters: GenerationSchema
    let executor: @Sendable (Data) async -> String

    func call(arguments: GeneratedContent) async -> String {
        await executor(Data(arguments.jsonString.utf8))
    }
}

enum AppleIntelligenceError: Error, LocalizedError {
    case noUserMessage
    case generation(String)

    var errorDescription: String? {
        switch self {
        case .noUserMessage:
            return "Aucun message utilisateur à envoyer."
        case .generation(let message):
            return message
        }
    }
}
