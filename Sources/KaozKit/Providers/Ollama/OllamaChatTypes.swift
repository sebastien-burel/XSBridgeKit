import Foundation

/// One NDJSON line returned by Ollama's `/api/chat`. Each chunk contains a
/// snapshot of the assistant message; subsequent chunks REPLACE rather than
/// extend (Ollama's API protocol). `message.content` ships the current text
/// delta; `message.tool_calls` carries any tool invocations the model
/// produced this round (atomic — Ollama doesn't stream arguments).
public struct OllamaChatChunk: Decodable {
    public struct Message: Decodable {
        public let role: String?
        public let content: String
        public let toolCalls: [ToolCall]?

        enum CodingKeys: String, CodingKey {
            case role, content
            case toolCalls = "tool_calls"
        }
    }

    public struct ToolCall: Decodable {
        public struct FunctionPayload: Decodable {
            public let name: String
            /// Decoded as raw JSON data so we can re-emit it as a string.
            /// Ollama sends arguments as a JSON object, not a string like
            /// OpenAI.
            public let arguments: RawJSON
        }
        public let function: FunctionPayload
    }

    public let message: Message
    public let done: Bool

    /// Performance counters, present only on the final (`done:true`) chunk.
    /// Durations are in nanoseconds. `evalCount`/`evalDuration` cover token
    /// generation (decode); the prompt_* pair covers prompt processing.
    public let evalCount: Int?
    public let evalDuration: Int?
    public let promptEvalCount: Int?
    public let promptEvalDuration: Int?

    enum CodingKeys: String, CodingKey {
        case message, done
        case evalCount = "eval_count"
        case evalDuration = "eval_duration"
        case promptEvalCount = "prompt_eval_count"
        case promptEvalDuration = "prompt_eval_duration"
    }
}

/// Type-erased wrapper that lets us decode arbitrary JSON into a Swift value
/// and re-encode it as a string. Used for tool-call arguments (Ollama emits
/// them as a JSON object; our protocol carries them as a JSON string).
public struct RawJSON: Decodable {
    public let value: Any

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: RawJSON].self) {
            self.value = dict.mapValues(\.value)
        } else if let array = try? container.decode([RawJSON].self) {
            self.value = array.map(\.value)
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let number = try? container.decode(Double.self) {
            self.value = number
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if container.decodeNil() {
            self.value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "RawJSON: unsupported value type"
            )
        }
    }

    public var jsonString: String {
        if let object = value as? [String: Any] {
            let safe = JSONSerialization.isValidJSONObject(object) ? object : [String: Any]()
            if let data = try? JSONSerialization.data(withJSONObject: safe),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "{}"
        }
        if let array = value as? [Any] {
            if let data = try? JSONSerialization.data(withJSONObject: array),
               let str = String(data: data, encoding: .utf8) {
                return str
            }
            return "[]"
        }
        if let s = value as? String { return "\"\(s)\"" }
        if let n = value as? Double { return "\(n)" }
        if let b = value as? Bool { return b ? "true" : "false" }
        return "null"
    }
}
