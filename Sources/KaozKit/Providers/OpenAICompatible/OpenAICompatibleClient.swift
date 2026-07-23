import Foundation

public enum OpenAICompatibleError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case network(message: String)
    case http(status: Int, body: String? = nil)
    case decoding(message: String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Clé API manquante."
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

/// Generic HTTP client for any provider that exposes the OpenAI v1 chat
/// completions API (Mistral, OpenAI, DeepSeek, ...). The auth header is a
/// Bearer token by default; specific providers can subclass / wrap if they
/// need something different.
public struct OpenAICompatibleClient {
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Embeddings

    /// OpenAI-standard `/embeddings` request. Used by the wiki when
    /// the user routes embeddings through a vLLM / LM Studio /
    /// llama.cpp server rather than Ollama.
    func embed(model: String, inputs: [String]) async throws -> [[Float]] {
        guard !inputs.isEmpty else { return [] }

        var request = URLRequest(url: baseURL.appending(path: "/embeddings"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 60

        let body: [String: Any] = ["model": model, "input": inputs]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenAICompatibleError.http(
                status: http.statusCode,
                body: (body?.isEmpty == false) ? body : nil
            )
        }

        struct EmbedResponse: Decodable {
            struct Item: Decodable {
                let embedding: [Float]
                let index: Int
            }
            let data: [Item]
        }
        do {
            let decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
            // The OpenAI spec doesn't guarantee order — sort by `index`
            // so callers can zip results back to their input array.
            return decoded.data.sorted { $0.index < $1.index }.map(\.embedding)
        } catch {
            throw OpenAICompatibleError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - List models

    public func listModels() async throws -> [OpenAICompatibleModelsResponse.Model] {
        var request = URLRequest(url: baseURL.appending(path: "/models"))
        request.timeoutInterval = 10
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OpenAICompatibleError.http(status: http.statusCode)
        }
        do {
            return try JSONDecoder().decode(OpenAICompatibleModelsResponse.self, from: data).data
        } catch {
            throw OpenAICompatibleError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - Chat (streaming)

    func chat(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Image-generation models (gpt-image-1, dall-e) live on
                    // the Images API, not /chat/completions. Route them so
                    // the UX matches Gemini: prompt in, image attachment out.
                    if Self.isImageGenerationModel(model) {
                        let images = messages.last { $0.role == .user }?.imageURLs ?? []
                        let m = model.lowercased()
                        // OpenAI image models edit an attached image via the
                        // dedicated /images/edits endpoint; otherwise generate.
                        if !images.isEmpty, m.contains("gpt-image") || m.contains("dall-e") {
                            try await runImageEdit(
                                model: model, messages: messages, images: images,
                                continuation: continuation)
                        } else {
                            try await runImageGeneration(
                                model: model, messages: messages, continuation: continuation)
                        }
                        continuation.finish()
                        return
                    }
                    // Qwen image models use DashScope's native
                    // multimodal-generation endpoint (not chat completions).
                    if Self.isQwenImageModel(model) {
                        try await runQwenImageGeneration(
                            model: model, messages: messages, continuation: continuation)
                        continuation.finish()
                        return
                    }

                    var request = URLRequest(url: baseURL.appending(path: "/chat/completions"))
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue(
                        "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
                        forHTTPHeaderField: "Authorization"
                    )
                    request.timeoutInterval = 60
                    request.httpBody = try Self.buildBody(model: model, messages: messages, tools: tools)

                    let (bytes, response): (URLSession.AsyncBytes, URLResponse)
                    do {
                        (bytes, response) = try await session.bytes(for: request)
                    } catch let urlError as URLError {
                        throw OpenAICompatibleError.network(message: urlError.localizedDescription)
                    }

                    guard let http = response as? HTTPURLResponse else {
                        throw OpenAICompatibleError.network(message: "réponse non-HTTP")
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        // Read the body so the user sees what the provider
                        // actually complained about (DeepSeek/OpenAI/Mistral
                        // all return JSON error bodies with details).
                        var body = ""
                        for try await byte in bytes {
                            body.append(Character(UnicodeScalar(byte)))
                            if body.count > 1500 { break }
                        }
                        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                        throw OpenAICompatibleError.http(
                            status: http.statusCode,
                            body: trimmed.isEmpty ? nil : trimmed
                        )
                    }

                    // Accumulators for tool-call deltas, keyed by the
                    // provider-assigned `index`. We only emit a complete
                    // .toolCall event once the finish_reason arrives.
                    var accumulators: [Int: (id: String, name: String, args: String)] = [:]

                    func flushToolCalls() {
                        for index in accumulators.keys.sorted() {
                            let acc = accumulators[index]!
                            continuation.yield(.toolCall(
                                id: acc.id,
                                name: acc.name,
                                argumentsJSON: acc.args
                            ))
                        }
                        accumulators.removeAll()
                    }

                    // Client-side timing for the benchmark metrics. The
                    // server reports token counts but no durations, so we
                    // clock first/last token off the byte stream ourselves.
                    let clock = ContinuousClock()
                    let requestStart = clock.now
                    var firstToken: ContinuousClock.Instant?
                    var lastToken: ContinuousClock.Instant?

                    func absorb(_ info: LineInfo) {
                        if let delta = info.textDelta {
                            if firstToken == nil { firstToken = clock.now }
                            lastToken = clock.now
                            continuation.yield(.textDelta(delta))
                        }
                        if let reasoning = info.reasoningDelta {
                            if firstToken == nil { firstToken = clock.now }
                            lastToken = clock.now
                            continuation.yield(.reasoningDelta(reasoning))
                        }
                        for tcDelta in info.toolCallDeltas {
                            let index = tcDelta.index ?? 0
                            if var acc = accumulators[index] {
                                if let id = tcDelta.id, acc.id.isEmpty { acc.id = id }
                                if let name = tcDelta.name, acc.name.isEmpty { acc.name = name }
                                if let argsDelta = tcDelta.argumentsDelta { acc.args += argsDelta }
                                accumulators[index] = acc
                            } else {
                                accumulators[index] = (
                                    id: tcDelta.id ?? "",
                                    name: tcDelta.name ?? "",
                                    args: tcDelta.argumentsDelta ?? ""
                                )
                            }
                        }
                    }

                    // `usage` arrives in a trailing chunk *after* finish_reason
                    // (and before [DONE]). So we don't bail on the first `done`
                    // — we flush tool calls, then keep draining for the usage
                    // chunk, and break on the second `done` ([DONE]) or EOF.
                    var usage: LineInfo.Usage?
                    var sawDone = false
                    var buffer = Data()
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A {
                            let info = try Self.parseLine(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            if let u = info.usage { usage = u }
                            if info.done {
                                if sawDone { break }   // [DONE] after the usage chunk
                                absorb(info)
                                flushToolCalls()
                                sawDone = true
                            } else if !sawDone {
                                absorb(info)
                            }
                        } else {
                            buffer.append(byte)
                        }
                    }
                    if !buffer.isEmpty {
                        let info = try Self.parseLine(buffer)
                        if let u = info.usage { usage = u }
                        if !sawDone { absorb(info) }
                    }
                    if !sawDone { flushToolCalls() }

                    var metrics = GenerationMetrics()
                    metrics.promptTokens = usage?.promptTokens
                    metrics.completionTokens = usage?.completionTokens
                    if let firstToken {
                        metrics.timeToFirstToken = Self.seconds(requestStart.duration(to: firstToken))
                        if let lastToken {
                            metrics.generationDuration = Self.seconds(firstToken.duration(to: lastToken))
                        }
                    }
                    if metrics != GenerationMetrics() {
                        continuation.yield(.metrics(metrics))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Parsing one SSE line

    /// What `parseLine` returns: text delta if any, tool-call deltas if any,
    /// and the `done` flag (sentinel `[DONE]` or `finish_reason != nil`).
    struct LineInfo: Equatable {
        let textDelta: String?
        let toolCallDeltas: [ToolCallDeltaInfo]
        let reasoningDelta: String?
        let done: Bool
        /// Token counts if this chunk carried a `usage` block, else nil.
        let usage: Usage?

        struct Usage: Equatable {
            let promptTokens: Int?
            let completionTokens: Int?
        }

        struct ToolCallDeltaInfo: Equatable {
            let index: Int?
            let id: String?
            let name: String?
            let argumentsDelta: String?
        }

        init(
            textDelta: String?,
            toolCallDeltas: [ToolCallDeltaInfo],
            reasoningDelta: String?,
            done: Bool,
            usage: Usage? = nil
        ) {
            self.textDelta = textDelta
            self.toolCallDeltas = toolCallDeltas
            self.reasoningDelta = reasoningDelta
            self.done = done
            self.usage = usage
        }
    }

    /// Parses one SSE line. Blank lines, `event:` and `id:` preambles are
    /// no-ops. `data: [DONE]` flips `done`. Malformed JSON in a `data:`
    /// payload throws.
    static func parseLine(_ raw: Data) throws -> LineInfo {
        guard let line = String(data: raw, encoding: .utf8) else {
            return LineInfo(textDelta: nil, toolCallDeltas: [], reasoningDelta: nil, done: false)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return LineInfo(textDelta: nil, toolCallDeltas: [], reasoningDelta: nil, done: false) }
        guard trimmed.hasPrefix("data:") else { return LineInfo(textDelta: nil, toolCallDeltas: [], reasoningDelta: nil, done: false) }

        let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return LineInfo(textDelta: nil, toolCallDeltas: [], reasoningDelta: nil, done: true)
        }
        guard let data = payload.data(using: .utf8) else {
            return LineInfo(textDelta: nil, toolCallDeltas: [], reasoningDelta: nil, done: false)
        }

        do {
            let chunk = try JSONDecoder().decode(OpenAICompatibleChunk.self, from: data)
            let usage = chunk.usage.map {
                LineInfo.Usage(promptTokens: $0.promptTokens, completionTokens: $0.completionTokens)
            }
            guard let choice = (chunk.choices ?? []).first else {
                // Trailing usage-only chunk: no choices, just token counts.
                return LineInfo(textDelta: nil, toolCallDeltas: [], reasoningDelta: nil, done: false, usage: usage)
            }

            let delta = choice.delta
            let textDelta = (delta?.content?.isEmpty ?? true) ? nil : delta?.content
            let reasoningDelta = (delta?.reasoningContent?.isEmpty ?? true) ? nil : delta?.reasoningContent

            let tcDeltas = (delta?.toolCalls ?? []).map { tc in
                LineInfo.ToolCallDeltaInfo(
                    index: tc.index,
                    id: tc.id,
                    name: tc.function?.name,
                    argumentsDelta: tc.function?.arguments
                )
            }

            return LineInfo(
                textDelta: textDelta,
                toolCallDeltas: tcDeltas,
                reasoningDelta: reasoningDelta,
                done: choice.finishReason != nil,
                usage: usage
            )
        } catch {
            throw OpenAICompatibleError.decoding(message: error.localizedDescription)
        }
    }

    // MARK: - Image generation (Images API)

    /// True for models served by the OpenAI-style `/images/generations`
    /// endpoint: OpenAI (gpt-image-1, dall-e) and z.ai CogView. Qwen uses a
    /// different native endpoint — see `isQwenImageModel`.
    static func isImageGenerationModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("gpt-image") || m.contains("dall-e") || m.contains("cogview")
    }

    /// Generates an image from the last user message via the OpenAI-style
    /// Images API and emits it as a single `.imageOutput`. Handles both
    /// `b64_json` (OpenAI) and `url` (z.ai CogView) responses. Non-streaming.
    private func runImageGeneration(
        model: String,
        messages: [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let prompt = messages.last { $0.role == .user }?.content ?? ""
        let m = model.lowercased()

        var request = URLRequest(url: baseURL.appending(path: "/images/generations"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 120

        var body: [String: Any] = ["model": model, "prompt": prompt]
        if m.contains("cogview") {
            body["size"] = "1024x1024"                 // z.ai CogView
        } else {
            body["n"] = 1
            if m.contains("dall-e") {                  // dall-e needs the flag
                body["response_format"] = "b64_json"   // gpt-image-1 returns b64 by default
            }
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenAICompatibleError.http(
                status: http.statusCode,
                body: (text?.isEmpty == false) ? text : nil
            )
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let first = (json?["data"] as? [[String: Any]])?.first
        if let b64 = first?["b64_json"] as? String, let imageData = Data(base64Encoded: b64) {
            continuation.yield(.imageOutput(data: imageData, mimeType: "image/png"))
        } else if let urlString = first?["url"] as? String, let imageURL = URL(string: urlString) {
            // CogView returns a temporary URL — fetch the bytes.
            let imageData: Data
            do {
                (imageData, _) = try await session.data(from: imageURL)
            } catch let urlError as URLError {
                throw OpenAICompatibleError.network(message: urlError.localizedDescription)
            }
            let mime = ["jpg", "jpeg"].contains(imageURL.pathExtension.lowercased())
                ? "image/jpeg" : "image/png"
            continuation.yield(.imageOutput(data: imageData, mimeType: mime))
        } else {
            throw OpenAICompatibleError.decoding(message: "réponse image sans b64_json ni url")
        }
    }

    /// Edits attached image(s) per the prompt via OpenAI's `/images/edits`
    /// (multipart). gpt-image-1 returns `b64_json`.
    private func runImageEdit(
        model: String,
        messages: [ChatMessage],
        images: [URL],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let prompt = messages.last { $0.role == .user }?.content ?? ""
        let boundary = "tykaoz-\(UUID().uuidString)"

        var request = URLRequest(url: baseURL.appending(path: "/images/edits"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 120
        request.httpBody = Self.multipartBody(
            boundary: boundary, fields: ["model": model, "prompt": prompt], images: images)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenAICompatibleError.http(
                status: http.statusCode, body: (text?.isEmpty == false) ? text : nil)
        }

        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let b64 = (json?["data"] as? [[String: Any]])?.first?["b64_json"] as? String,
              let imageData = Data(base64Encoded: b64) else {
            throw OpenAICompatibleError.decoding(message: "réponse édition sans b64_json")
        }
        continuation.yield(.imageOutput(data: imageData, mimeType: "image/png"))
    }

    /// Builds a multipart/form-data body with text fields and image files
    /// (each as `image[]`, which gpt-image-1 accepts for one or many).
    static func multipartBody(boundary: String, fields: [String: String], images: [URL]) -> Data {
        var body = Data()
        func append(_ string: String) { body.append(Data(string.utf8)) }
        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        for url in images {
            guard let data = try? Data(contentsOf: url) else { continue }
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"image[]\"; filename=\"\(url.lastPathComponent)\"\r\n")
            append("Content-Type: \(ImageContent.mimeType(for: url))\r\n\r\n")
            body.append(data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }

    // MARK: - Qwen image generation (DashScope native)

    /// True for DashScope (Qwen) text-to-image models, which use the native
    /// `multimodal-generation` endpoint rather than chat completions.
    public static func isQwenImageModel(_ model: String) -> Bool {
        let m = model.lowercased()
        return m.contains("qwen-image") || m.hasPrefix("wan")
    }

    /// Extracts the generated image URL from a DashScope multimodal
    /// response: `output.choices[0].message.content[].image`.
    static func parseQwenImageURL(_ data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [String: Any],
              let choices = output["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else {
            return nil
        }
        return content.compactMap { $0["image"] as? String }.first
    }

    /// Generates an image via DashScope's native endpoint, fetches the
    /// returned (temporary) URL, and emits it as one `.imageOutput`.
    private func runQwenImageGeneration(
        model: String,
        messages: [ChatMessage],
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async throws {
        let prompt = messages.last { $0.role == .user }?.content ?? ""

        // Derive the native endpoint from the compatible-mode base URL
        // (same host, different path).
        guard let scheme = baseURL.scheme, let host = baseURL.host else {
            throw OpenAICompatibleError.network(message: "URL de base invalide")
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/api/v1/services/aigc/multimodal-generation/generation"
        guard let endpoint = components.url else {
            throw OpenAICompatibleError.network(message: "URL DashScope invalide")
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))",
            forHTTPHeaderField: "Authorization"
        )
        request.timeoutInterval = 120

        // Attached images turn this into an edit: include them in the
        // content before the text. Size only applies to from-scratch gen.
        let images = messages.last { $0.role == .user }?.imageURLs ?? []
        var content: [[String: Any]] = images.compactMap { url in
            guard let (mime, b64) = ImageContent.encode(url) else { return nil }
            return ["image": "data:\(mime);base64,\(b64)"]
        }
        content.append(["text": prompt])

        var parameters: [String: Any] = ["prompt_extend": true, "watermark": false]
        if images.isEmpty {
            parameters["size"] = "1328*1328"
            parameters["n"] = 1
        }
        let body: [String: Any] = [
            "model": model,
            "input": ["messages": [["role": "user", "content": content]]],
            "parameters": parameters,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleError.network(message: "réponse non-HTTP")
        }
        guard (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpenAICompatibleError.http(
                status: http.statusCode,
                body: (text?.isEmpty == false) ? text : nil
            )
        }

        guard let urlString = Self.parseQwenImageURL(data),
              let imageURL = URL(string: urlString) else {
            throw OpenAICompatibleError.decoding(message: "réponse image Qwen sans URL")
        }

        // Fetch the generated image (temporary signed URL).
        let imageData: Data
        do {
            (imageData, _) = try await session.data(from: imageURL)
        } catch let urlError as URLError {
            throw OpenAICompatibleError.network(message: urlError.localizedDescription)
        }
        let mime = imageURL.pathExtension.lowercased() == "jpg"
            || imageURL.pathExtension.lowercased() == "jpeg" ? "image/jpeg" : "image/png"
        continuation.yield(.imageOutput(data: imageData, mimeType: mime))
    }

    // MARK: - Request body

    /// Builds the request body as a dictionary so we can splice each tool's
    /// raw JSON Schema in as a proper JSON object (Codable can't embed
    /// arbitrary JSON without gymnastics).
    /// Converts a monotonic `Duration` to seconds as a Double.
    static func seconds(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }

    static func buildBody(
        model: String,
        messages: [ChatMessage],
        tools: [ToolSpec]
    ) throws -> Data {
        var dict: [String: Any] = [
            "model": model,
            "stream": true,
            // Ask the server to append a token-usage chunk before [DONE], so
            // we can report prompt/completion counts. Standard OpenAI option,
            // honoured by vLLM, NIM, LM Studio, llama.cpp and the cloud hosts.
            "stream_options": ["include_usage": true],
            "messages": try messagesToDicts(messages)
        ]
        if !tools.isEmpty {
            dict["tools"] = try tools.map { spec -> [String: Any] in
                let parameters = try JSONSerialization.jsonObject(
                    with: Data(spec.inputSchemaJSON.utf8)
                )
                return [
                    "type": "function",
                    "function": [
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": parameters
                    ] as [String: Any]
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: dict, options: [])
    }

    /// Converts our internal chat history to the OpenAI-compatible wire
    /// shape. Consecutive `.assistant` + `.toolCall` entries merge into a
    /// single assistant message with a `tool_calls` array; `.toolResult`
    /// entries become role="tool" messages with `tool_call_id`.
    static func messagesToDicts(_ messages: [ChatMessage]) throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var i = 0
        while i < messages.count {
            let msg = messages[i]
            switch msg.role {
            case .user, .system:
                if msg.role == .user, !msg.imageURLs.isEmpty {
                    // Multimodal: content becomes an array of parts (text +
                    // image_url data URLs) for vision-capable models.
                    var parts: [[String: Any]] = ImageContent.openAIParts(for: msg.imageURLs)
                    if !msg.content.isEmpty {
                        parts.insert(["type": "text", "text": msg.content], at: 0)
                    }
                    out.append(["role": "user", "content": parts])
                } else {
                    out.append([
                        "role": msg.role.rawValue,
                        "content": msg.content
                    ])
                }
                i += 1

            case .assistant:
                var dict: [String: Any] = [
                    "role": "assistant",
                    "content": msg.content
                ]
                if let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                    dict["reasoning_content"] = reasoning
                }
                var calls: [[String: Any]] = []
                var j = i + 1
                while j < messages.count, messages[j].role == .toolCall {
                    if let id = messages[j].toolCallID, let name = messages[j].toolName {
                        calls.append([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": messages[j].content
                            ] as [String: Any]
                        ])
                    }
                    j += 1
                }
                if !calls.isEmpty { dict["tool_calls"] = calls }
                out.append(dict)
                i = j

            case .toolCall:
                // Orphan tool call (no preceding assistant). Synthesise an
                // assistant message holding just the tool_calls array.
                var calls: [[String: Any]] = []
                var j = i
                while j < messages.count, messages[j].role == .toolCall {
                    if let id = messages[j].toolCallID, let name = messages[j].toolName {
                        calls.append([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": messages[j].content
                            ] as [String: Any]
                        ])
                    }
                    j += 1
                }
                out.append([
                    "role": "assistant",
                    "content": "",
                    "tool_calls": calls
                ])
                i = j

            case .toolResult:
                out.append([
                    "role": "tool",
                    "tool_call_id": msg.toolCallID ?? "",
                    "content": msg.content
                ])
                i += 1
            }
        }
        return out
    }
}
