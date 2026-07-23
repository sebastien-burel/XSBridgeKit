import Foundation

/// Decoded shape of one streamed chunk from the OpenAI-compatible
/// `/v1/chat/completions` API (used by OpenAI, Mistral, DeepSeek). Both
/// content text and partial tool-call payloads can appear, sometimes
/// together.
public struct OpenAICompatibleChunk: Decodable {
    public struct Choice: Decodable {
        public struct Delta: Decodable {
            public let content: String?
            public let toolCalls: [ToolCallDelta]?
            public let reasoningContent: String?

            enum CodingKeys: String, CodingKey {
                case content
                case toolCalls = "tool_calls"
                case reasoningContent = "reasoning_content"
            }
        }

        public struct ToolCallDelta: Decodable {
            public let index: Int?
            public let id: String?
            /// "function" in the current API; carried as-is for forwards
            /// compatibility but we don't switch on it.
            public let type: String?
            public let function: FunctionDelta?
        }

        public struct FunctionDelta: Decodable {
            public let name: String?
            public let arguments: String?
        }

        /// Optional: some providers (e.g. Qwen reasoning models) emit
        /// choices with no `delta` on certain chunks. A missing delta must
        /// not abort the whole stream.
        public let delta: Delta?
        public let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    /// Token accounting. Present only when the request opts in via
    /// `stream_options.include_usage`; it then arrives in a trailing chunk
    /// (with `choices` empty) just before `[DONE]`. Some servers also inline
    /// it on the final content chunk.
    public struct Usage: Decodable {
        public let promptTokens: Int?
        public let completionTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
        }
    }

    /// Optional: a trailing usage-only chunk, or an occasional metadata
    /// chunk, can arrive without any `choices` key. Decode it as empty
    /// rather than throwing.
    public let choices: [Choice]?
    public let usage: Usage?
}

public struct OpenAICompatibleModelsResponse: Decodable {
    public struct Model: Decodable, Identifiable, Hashable {
        public let id: String
    }
    public let data: [Model]
}
