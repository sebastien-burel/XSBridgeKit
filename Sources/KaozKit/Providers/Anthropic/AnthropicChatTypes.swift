import Foundation

/// One streaming event from Anthropic's `/v1/messages` SSE response.
/// Anthropic emits a structured sequence: message_start → one or more
/// content_block_start/delta/stop pairs → message_delta → message_stop.
/// The same event shape is shared across types; the `type` discriminator
/// tells us which fields are populated.
public struct AnthropicStreamEvent: Decodable {
    public let type: String
    public let index: Int?
    public let contentBlock: ContentBlock?
    public let delta: Delta?

    public struct ContentBlock: Decodable {
        public let type: String          // "text" or "tool_use"
        public let id: String?           // populated for tool_use
        public let name: String?         // populated for tool_use
    }

    public struct Delta: Decodable {
        public let type: String?         // "text_delta", "input_json_delta", "stop_reason", ...
        public let text: String?         // for text_delta
        public let partialJSON: String?  // for input_json_delta

        enum CodingKeys: String, CodingKey {
            case type, text
            case partialJSON = "partial_json"
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, index, delta
        case contentBlock = "content_block"
    }
}

public struct AnthropicModelsResponse: Decodable {
    public struct Model: Decodable, Identifiable, Hashable {
        public let id: String
        public let displayName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case displayName = "display_name"
        }
    }
    public let data: [Model]
}
