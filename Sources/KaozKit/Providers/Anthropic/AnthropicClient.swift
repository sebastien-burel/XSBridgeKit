import Foundation

public enum AnthropicClientError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case network(message: String)
    case http(status: Int, body: String? = nil)
    case decoding(message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Clé API Anthropic manquante."
        case .network(let msg):
            return "Erreur réseau : \(msg)"
        case .http(let status, let body):
            if let body, !body.isEmpty {
                return "Réponse HTTP \(status) : \(body)"
            }
            return "Réponse HTTP \(status)."
        case .decoding(let msg):
            return "Réponse inattendue : \(msg)"
        }
    }
}

public struct AnthropicClient {
    public let apiKey: String
    public let session: URLSession
    public let baseURL: URL
    public let anthropicVersion: String

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.anthropic.com/v1")!,
        anthropicVersion: String = "2023-06-01",
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.anthropicVersion = anthropicVersion
        self.session = session
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue(trimmedAPIKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
    }

    // MARK: - List models

    public func listModels() async throws -> [AnthropicModelsResponse.Model] {
        var request = URLRequest(url: baseURL.appending(path: "/models"))
        request.timeoutInterval = 10
        authorize(&request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw AnthropicClientError.network(message: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicClientError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicClientError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(AnthropicModelsResponse.self, from: data).data
        } catch {
            throw AnthropicClientError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - Chat (streaming)

    public func chat(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec],
        maxTokens: Int = 4096
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: baseURL.appending(path: "/messages"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    authorize(&request)
                    request.timeoutInterval = 60
                    request.httpBody = try Self.buildBody(
                        model: model,
                        messages: messages,
                        tools: tools,
                        maxTokens: maxTokens
                    )

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch let urlError as URLError {
                        throw AnthropicClientError.network(message: urlError.localizedDescription)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw AnthropicClientError.network(message: "réponse non-HTTP")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await byte in bytes {
                            body.append(Character(UnicodeScalar(byte)))
                            if body.count > 1500 { break }
                        }
                        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw AnthropicClientError.http(
                            status: http.statusCode,
                            body: trimmed.isEmpty ? nil : trimmed
                        )
                    }

                    // Per-index block tracker. Tool-use blocks accumulate
                    // their input JSON across input_json_delta chunks; they
                    // emit a complete StreamEvent.toolCall on
                    // content_block_stop. BlockState lives at file scope
                    // (see end of struct).
                    var blocks: [Int: BlockState] = [:]

                    var buffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A {
                            try Self.handleLine(
                                buffer,
                                blocks: &blocks,
                                continuation: continuation
                            )
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        try Self.handleLine(
                            buffer,
                            blocks: &blocks,
                            continuation: continuation
                        )
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - SSE line handling

    /// Routes one SSE line into the per-block accumulator and emits
    /// StreamEvents as appropriate. Throws on malformed JSON in a `data:`
    /// payload.
    fileprivate static func handleLine(
        _ raw: Data,
        blocks: inout [Int: BlockState],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) throws {
        let info = try parseLine(raw)
        guard let event = info.event else { return }

        switch event.type {
        case "content_block_start":
            guard let index = event.index, let block = event.contentBlock else { return }
            var state = BlockState(kind: block.type)
            if block.type == "tool_use" {
                state.toolID = block.id ?? ""
                state.toolName = block.name ?? ""
            }
            blocks[index] = state

        case "content_block_delta":
            guard let index = event.index, let delta = event.delta else { return }
            switch delta.type {
            case "text_delta":
                if let text = delta.text, !text.isEmpty {
                    continuation.yield(.textDelta(text))
                }
            case "input_json_delta":
                if var state = blocks[index], let partial = delta.partialJSON {
                    state.args += partial
                    blocks[index] = state
                }
            default:
                break
            }

        case "content_block_stop":
            guard let index = event.index, let state = blocks[index] else { return }
            if state.kind == "tool_use" {
                continuation.yield(.toolCall(
                    id: state.toolID,
                    name: state.toolName,
                    argumentsJSON: state.args
                ))
            }
            blocks.removeValue(forKey: index)

        case "message_stop":
            // The for-await loop will exit naturally; nothing else to do.
            break

        default:
            // message_start, message_delta, ping, ... — irrelevant.
            break
        }
    }

    /// Internal per-block accumulator type. fileprivate so tests can't poke
    /// at it accidentally.
    fileprivate struct BlockState {
        var kind: String
        var toolID: String = ""
        var toolName: String = ""
        var args: String = ""
    }

    // MARK: - Line parsing

    /// What `parseLine` returns: the decoded AnthropicStreamEvent (or nil
    /// for blank lines / `event:` preambles) and whether the line marks the
    /// final `message_stop` event.
    public struct LineInfo: Equatable {
        public let event: AnthropicStreamEvent?

        public static func == (lhs: LineInfo, rhs: LineInfo) -> Bool {
            // Equatable approximation for tests — compare event.type only.
            lhs.event?.type == rhs.event?.type
        }
    }

    public static func parseLine(_ raw: Data) throws -> LineInfo {
        guard let line = String(data: raw, encoding: .utf8) else { return LineInfo(event: nil) }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data:") else { return LineInfo(event: nil) }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else { return LineInfo(event: nil) }

        do {
            let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
            return LineInfo(event: event)
        } catch {
            throw AnthropicClientError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - Request body

    /// Builds the request body as a dictionary so each tool's raw JSON
    /// Schema and parsed tool arguments can be spliced in as proper JSON
    /// objects.
    public static func buildBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec],
        maxTokens: Int
    ) throws -> Data {
        // System messages are concatenated into the top-level `system`
        // parameter; they don't go in the messages array.
        let systemBits = messages.filter { $0.role == .system }.map(\.content)
        let system = systemBits.isEmpty ? nil : systemBits.joined(separator: "\n\n")

        var dict: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "stream": true,
            "messages": try messagesToDicts(messages)
        ]
        if let system, !system.isEmpty { dict["system"] = system }
        if !tools.isEmpty {
            dict["tools"] = try tools.map { spec -> [String: Any] in
                let schema = try JSONSerialization.jsonObject(with: Data(spec.inputSchemaJSON.utf8))
                return [
                    "name": spec.name,
                    "description": spec.description,
                    "input_schema": schema
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    /// Converts our flat ChatMessage history into Anthropic's content-block
    /// format. Assistant text + following toolCalls collapse into one
    /// assistant message with mixed `text` + `tool_use` blocks. Consecutive
    /// toolResult messages collapse into one user message with multiple
    /// `tool_result` blocks. System messages are skipped (they go top-level).
    public static func messagesToDicts(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            switch msg.role {
            case .system:
                i += 1

            case .user:
                // Image blocks first, then the text block (Anthropic
                // vision format). Images come from local attachment URLs.
                var content: [[String: Any]] = ImageContent.anthropicBlocks(for: msg.imageURLs)
                content.append(["type": "text", "text": msg.content])
                out.append([
                    "role": "user",
                    "content": content
                ])
                i += 1

            case .assistant:
                var blocks: [[String: Any]] = []
                if !msg.content.isEmpty {
                    blocks.append(["type": "text", "text": msg.content])
                }
                var j = i + 1
                while j < messages.count, messages[j].role == .toolCall {
                    if let id = messages[j].toolCallID, let name = messages[j].toolName {
                        let input = parseToolInput(messages[j].content)
                        blocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": input
                        ])
                    }
                    j += 1
                }
                if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
                i = j

            case .toolCall:
                // Orphan tool calls (no preceding assistant). Synthesise an
                // assistant message containing only tool_use blocks.
                var blocks: [[String: Any]] = []
                var j = i
                while j < messages.count, messages[j].role == .toolCall {
                    if let id = messages[j].toolCallID, let name = messages[j].toolName {
                        let input = parseToolInput(messages[j].content)
                        blocks.append([
                            "type": "tool_use",
                            "id": id,
                            "name": name,
                            "input": input
                        ])
                    }
                    j += 1
                }
                if !blocks.isEmpty {
                    out.append(["role": "assistant", "content": blocks])
                }
                i = j

            case .toolResult:
                var blocks: [[String: Any]] = []
                var j = i
                while j < messages.count, messages[j].role == .toolResult {
                    var block: [String: Any] = [
                        "type": "tool_result",
                        "tool_use_id": messages[j].toolCallID ?? "",
                        "content": messages[j].content
                    ]
                    if messages[j].toolIsError == true {
                        block["is_error"] = true
                    }
                    blocks.append(block)
                    j += 1
                }
                out.append(["role": "user", "content": blocks])
                i = j
            }
        }
        return out
    }

    /// Anthropic expects `input` to be a JSON object. We store args as a raw
    /// JSON string in our Message; parse it back. Falls back to an empty
    /// object if parsing fails (shouldn't happen for well-formed providers).
    private static func parseToolInput(_ json: String) -> Any {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return parsed
    }
}
