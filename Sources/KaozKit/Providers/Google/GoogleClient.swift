import Foundation

public enum GoogleClientError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case network(message: String)
    case http(status: Int, body: String? = nil)
    case decoding(message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Clé API Google manquante."
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

public struct GoogleClient {
    public let apiKey: String
    public let session: URLSession
    public let baseURL: URL

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    private var trimmedAPIKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - List models

    public func listModels() async throws -> [GoogleModelsResponse.Model] {
        var request = URLRequest(url: baseURL.appending(path: "/models"))
        request.timeoutInterval = 10
        request.setValue(trimmedAPIKey, forHTTPHeaderField: "x-goog-api-key")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw GoogleClientError.network(message: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GoogleClientError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw GoogleClientError.http(status: http.statusCode)
        }
        do {
            let decoded = try JSONDecoder().decode(GoogleModelsResponse.self, from: data)
            return decoded.models.filter {
                $0.supportedGenerationMethods?.contains("generateContent") ?? true
            }
        } catch {
            throw GoogleClientError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - Chat (streaming)

    public func chat(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let path = "/models/\(model):streamGenerateContent"
                    var components = URLComponents(
                        url: baseURL.appending(path: path),
                        resolvingAgainstBaseURL: false
                    )!
                    components.queryItems = [URLQueryItem(name: "alt", value: "sse")]

                    var request = URLRequest(url: components.url!)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(trimmedAPIKey, forHTTPHeaderField: "x-goog-api-key")
                    request.timeoutInterval = 60
                    request.httpBody = try Self.buildBody(
                        model: model,
                        messages: messages,
                        tools: tools
                    )

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch let urlError as URLError {
                        throw GoogleClientError.network(message: urlError.localizedDescription)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw GoogleClientError.network(message: "réponse non-HTTP")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var body = ""
                        for try await byte in bytes {
                            body.append(Character(UnicodeScalar(byte)))
                            if body.count > 1500 { break }
                        }
                        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw GoogleClientError.http(
                            status: http.statusCode,
                            body: trimmed.isEmpty ? nil : trimmed
                        )
                    }

                    var buffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A {
                            let info = try Self.parseLine(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            if let delta = info.textDelta {
                                continuation.yield(.textDelta(delta))
                            }
                            for tc in info.toolCalls {
                                continuation.yield(.toolCall(
                                    id: tc.id,
                                    name: tc.name,
                                    argumentsJSON: tc.argumentsJSON,
                                    thoughtSignature: tc.thoughtSignature
                                ))
                            }
                            for img in info.images {
                                if let data = Data(base64Encoded: img.base64) {
                                    continuation.yield(.imageOutput(data: data, mimeType: img.mimeType))
                                }
                            }
                            if info.done {
                                continuation.finish()
                                return
                            }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        let info = try Self.parseLine(buffer)
                        if let delta = info.textDelta {
                            continuation.yield(.textDelta(delta))
                        }
                        for tc in info.toolCalls {
                            continuation.yield(.toolCall(
                                id: tc.id,
                                name: tc.name,
                                argumentsJSON: tc.argumentsJSON,
                                thoughtSignature: tc.thoughtSignature
                            ))
                        }
                        for img in info.images {
                            if let data = Data(base64Encoded: img.base64) {
                                continuation.yield(.imageOutput(data: data, mimeType: img.mimeType))
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Line parsing

    public struct LineInfo: Equatable {
        public let textDelta: String?
        public let toolCalls: [ToolCallInfo]
        public let images: [ImageInfo]
        public let done: Bool

        public struct ToolCallInfo: Equatable {
            public let id: String
            public let name: String
            public let argumentsJSON: String
            public let thoughtSignature: String?
        }

        /// An inline image part: MIME type + base64 payload (decoded in
        /// `chat` so `parseLine` stays string-only).
        public struct ImageInfo: Equatable {
            public let mimeType: String
            public let base64: String
        }
    }

    /// Parses one SSE line from `?alt=sse`. Gemini emits each function call
    /// atomically inside `parts[].functionCall` (no per-character streaming
    /// like OpenAI), so we can synthesise a complete ToolCall right here.
    /// Text fragments from multiple parts in the same chunk are
    /// concatenated.
    public static func parseLine(_ raw: Data) throws -> LineInfo {
        guard let line = String(data: raw, encoding: .utf8) else {
            return LineInfo(textDelta: nil, toolCalls: [], images: [], done: false)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data:") else {
            return LineInfo(textDelta: nil, toolCalls: [], images: [], done: false)
        }
        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty, let data = payload.data(using: .utf8) else {
            return LineInfo(textDelta: nil, toolCalls: [], images: [], done: false)
        }

        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw GoogleClientError.decoding(message: error.localizedDescription)
        }

        guard let dict = json as? [String: Any],
              let candidates = dict["candidates"] as? [[String: Any]],
              let candidate = candidates.first else {
            return LineInfo(textDelta: nil, toolCalls: [], images: [], done: false)
        }

        let content = candidate["content"] as? [String: Any]
        let parts = content?["parts"] as? [[String: Any]] ?? []

        var collectedText: String? = nil
        var toolCalls: [LineInfo.ToolCallInfo] = []
        var images: [LineInfo.ImageInfo] = []

        for part in parts {
            if let text = part["text"] as? String, !text.isEmpty {
                collectedText = (collectedText ?? "") + text
            }
            // Inline image part (image-generation models). Gemini uses
            // camelCase `inlineData`; accept snake_case too for safety.
            if let inline = (part["inlineData"] ?? part["inline_data"]) as? [String: Any],
               let b64 = inline["data"] as? String, !b64.isEmpty {
                let mime = (inline["mimeType"] ?? inline["mime_type"]) as? String ?? "image/png"
                images.append(LineInfo.ImageInfo(mimeType: mime, base64: b64))
            }
            if let fc = part["functionCall"] as? [String: Any] {
                let name = fc["name"] as? String ?? ""
                let args = fc["args"] as? [String: Any] ?? [:]
                let argsData = (try? JSONSerialization.data(withJSONObject: args, options: [])) ?? Data("{}".utf8)
                let argsJSON = String(data: argsData, encoding: .utf8) ?? "{}"
                let id = (fc["id"] as? String) ?? UUID().uuidString
                // thoughtSignature lives next to functionCall on the part,
                // not inside it. Capture so we can echo it back on the next
                // round (Gemini 2.5+ refuses subsequent calls without it).
                let signature = part["thoughtSignature"] as? String
                toolCalls.append(LineInfo.ToolCallInfo(
                    id: id,
                    name: name,
                    argumentsJSON: argsJSON,
                    thoughtSignature: signature
                ))
            }
        }

        let done = (candidate["finishReason"] as? String) != nil
        return LineInfo(textDelta: collectedText, toolCalls: toolCalls, images: images, done: done)
    }

    // MARK: - Request body

    /// Builds the request body as a dictionary so the tool input schemas,
    /// function-call args, and function-response payloads all stay as
    /// proper JSON objects.
    public static func buildBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) throws -> Data {
        let systemBits = messages.filter { $0.role == .system }.map(\.content)
        let system = systemBits.isEmpty ? nil : systemBits.joined(separator: "\n\n")

        var dict: [String: Any] = [
            "contents": try contentsFromHistory(messages)
        ]

        if let system, !system.isEmpty {
            dict["systemInstruction"] = [
                "parts": [["text": system] as [String: Any]]
            ]
        }

        // Image-generation models (e.g. gemini-2.5-flash-image) only emit
        // images when both modalities are requested.
        if model.lowercased().contains("image") {
            dict["generationConfig"] = ["responseModalities": ["TEXT", "IMAGE"]]
        }

        if !tools.isEmpty {
            let declarations: [[String: Any]] = try tools.map { spec in
                let raw = try JSONSerialization.jsonObject(
                    with: Data(spec.inputSchemaJSON.utf8)
                )
                let parameters = sanitiseSchemaForGemini(raw)
                return [
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": parameters
                ]
            }
            dict["tools"] = [["functionDeclarations": declarations] as [String: Any]]
        }

        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    /// Reshapes our flat ChatMessage history into Gemini's contents format.
    /// Assistant turns (text + tool_calls) become a `model` content with
    /// mixed `text` and `functionCall` parts. Tool results become `user`
    /// content with one or more `functionResponse` parts (Gemini matches by
    /// function name, not id). System messages are skipped (top-level).
    public static func contentsFromHistory(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            switch msg.role {
            case .system:
                i += 1

            case .user:
                // Text part first, then inline image parts (Gemini vision).
                var parts: [[String: Any]] = [["text": msg.content]]
                parts.append(contentsOf: ImageContent.geminiParts(for: msg.imageURLs))
                out.append([
                    "role": "user",
                    "parts": parts
                ])
                i += 1

            case .assistant:
                var parts: [[String: Any]] = []
                if !msg.content.isEmpty {
                    parts.append(["text": msg.content])
                }
                // Feed back images the model generated so a follow-up like
                // "make it blue" can edit the previous result without the
                // user re-attaching it.
                parts.append(contentsOf: ImageContent.geminiParts(for: msg.imageURLs))
                var j = i + 1
                while j < messages.count, messages[j].role == .toolCall {
                    if let name = messages[j].toolName {
                        let args = parseToolArgs(messages[j].content)
                        var part: [String: Any] = [
                            "functionCall": [
                                "name": name,
                                "args": args
                            ] as [String: Any]
                        ]
                        if let sig = messages[j].thoughtSignature, !sig.isEmpty {
                            part["thoughtSignature"] = sig
                        }
                        parts.append(part)
                    }
                    j += 1
                }
                if !parts.isEmpty {
                    out.append(["role": "model", "parts": parts])
                }
                i = j

            case .toolCall:
                // Orphan tool calls (no preceding assistant) — synthesise a
                // model content with only functionCall parts.
                var parts: [[String: Any]] = []
                var j = i
                while j < messages.count, messages[j].role == .toolCall {
                    if let name = messages[j].toolName {
                        let args = parseToolArgs(messages[j].content)
                        var part: [String: Any] = [
                            "functionCall": [
                                "name": name,
                                "args": args
                            ] as [String: Any]
                        ]
                        if let sig = messages[j].thoughtSignature, !sig.isEmpty {
                            part["thoughtSignature"] = sig
                        }
                        parts.append(part)
                    }
                    j += 1
                }
                if !parts.isEmpty {
                    out.append(["role": "model", "parts": parts])
                }
                i = j

            case .toolResult:
                var parts: [[String: Any]] = []
                var j = i
                while j < messages.count, messages[j].role == .toolResult {
                    let name = nameForCallID(messages[j].toolCallID, in: messages) ?? ""
                    parts.append([
                        "functionResponse": [
                            "name": name,
                            "response": [
                                "content": messages[j].content
                            ]
                        ] as [String: Any]
                    ])
                    j += 1
                }
                out.append(["role": "user", "parts": parts])
                i = j
            }
        }
        return out
    }

    /// Looks back through the history for the toolCall that produced this
    /// callID, so we can pair the functionResponse with its function NAME
    /// (which is what Gemini uses to correlate).
    private static func nameForCallID(_ id: String?, in messages: [ChatMessage]) -> String? {
        guard let id else { return nil }
        return messages.first(where: { $0.role == .toolCall && $0.toolCallID == id })?.toolName
    }

    /// Gemini's tool parameter schema follows an OpenAPI 3 subset, not the
    /// full JSON Schema spec. Fields like `additionalProperties` (valid
    /// JSON Schema) are rejected with HTTP 400. Strip them recursively
    /// before sending. Anything else passes through unchanged.
    public static func sanitiseSchemaForGemini(_ value: Any) -> Any {
        let droppedKeys: Set<String> = [
            "additionalProperties",
            "$schema",
            "$id",
            "$ref"
        ]
        if var dict = value as? [String: Any] {
            for key in droppedKeys { dict.removeValue(forKey: key) }
            for (k, v) in dict {
                dict[k] = sanitiseSchemaForGemini(v)
            }
            return dict
        }
        if let array = value as? [Any] {
            return array.map(sanitiseSchemaForGemini)
        }
        return value
    }

    private static func parseToolArgs(_ json: String) -> Any {
        guard let data = json.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) else {
            return [String: Any]()
        }
        return parsed
    }
}
