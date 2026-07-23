import Foundation

public enum ComfyUIError: Error, LocalizedError, Equatable {
    case network(message: String)
    case http(status: Int, body: String?)
    /// The server rejected the workflow at submit time (`node_errors`).
    case validation(message: String)
    /// The workflow doesn't contain the `%prompt%` marker, so there's
    /// nowhere to inject the chat message.
    case missingPromptPlaceholder
    case timeout
    case decoding(message: String)

    public var errorDescription: String? {
        switch self {
        case .network(let message):
            return "Erreur réseau : \(message)"
        case .http(let status, let body):
            if let body, !body.isEmpty {
                return "Réponse HTTP \(status) : \(body)"
            }
            return "Réponse HTTP \(status)."
        case .validation(let message):
            return "Workflow refusé par ComfyUI : \(message)"
        case .missingPromptPlaceholder:
            return "Le workflow ne contient pas le marqueur \(ComfyUIClient.promptPlaceholder)."
        case .timeout:
            return "La génération a dépassé le délai maximal."
        case .decoding(let message):
            return "Réponse inattendue : \(message)"
        }
    }
}

/// Talks to a ComfyUI server's HTTP API to run a text-to-image workflow:
/// submit the graph (`POST /prompt`), poll for completion
/// (`GET /history/{id}`), then download the rendered image (`GET /view`).
///
/// The "model" is a whole workflow (ComfyUI API-format JSON). The chat
/// prompt is injected wherever the workflow carries the `%prompt%` marker,
/// and every `seed` / `noise_seed` is re-randomised so repeated prompts vary.
public struct ComfyUIClient {
    public let baseURL: URL
    public let apiKey: String
    public let session: URLSession

    public static let promptPlaceholder = "%prompt%"

    public init(baseURL: URL, apiKey: String = "", session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    // MARK: - Availability

    /// True when `GET /system_stats` answers 2xx. Used for a quick
    /// reachability check without touching a workflow.
    public func systemStatsReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "/system_stats"))
        request.timeoutInterval = 10
        applyAuth(&request)
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return false }
        return true
    }

    // MARK: - Workflow preparation (pure)

    /// Parameter markers a workflow exposes, e.g. `%guidance=2.5%`. The
    /// reserved `%prompt%` is excluded — it's the chat message, not a knob.
    /// The `default` (after `=`) pre-fills the settings field. Each name is
    /// returned once, in first-seen order.
    public static func discoverParameters(in json: String) -> [(name: String, default: String)] {
        var seen = Set<String>()
        var out: [(name: String, default: String)] = []
        for match in json.matches(of: markerRegex) {
            guard let name = match.output[1].substring.map(String.init),
                  name != "prompt", seen.insert(name).inserted
            else { continue }
            out.append((name: name, default: match.output[2].substring.map(String.init) ?? ""))
        }
        return out
    }

    /// Builds the graph to submit. Injects `prompt` at every `%prompt%`
    /// marker; replaces each whole-value parameter marker (`%name%` /
    /// `%name=def%`) with `params[name]` (falling back to the marker default),
    /// coerced to a number when it parses as one; and replaces any bare
    /// numeric `seed` / `noise_seed` with `seed`. Re-serialisation via
    /// JSONSerialization handles escaping. Throws if `%prompt%` is absent or
    /// the JSON is malformed.
    public static func prepareWorkflow(
        json: String,
        prompt: String,
        params: [String: String] = [:],
        seed: Int
    ) throws -> [String: Any] {
        guard json.contains(promptPlaceholder) else {
            throw ComfyUIError.missingPromptPlaceholder
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            throw ComfyUIError.decoding(message: "workflow JSON invalide")
        }
        // Marker defaults overlaid with the user's stored values.
        var resolved: [String: String] = [:]
        for parameter in discoverParameters(in: json) { resolved[parameter.name] = parameter.default }
        for (key, value) in params { resolved[key] = value }

        guard let transformed = transform(root, prompt: prompt, params: resolved, seed: seed) as? [String: Any] else {
            throw ComfyUIError.decoding(message: "workflow JSON invalide")
        }
        return transformed
    }

    private static let markerRegex = try! Regex("%([A-Za-z_][A-Za-z0-9_]*)(?:=([^%]*))?%")

    /// Recursively substitutes prompt / parameter markers and randomises
    /// bare numeric seeds.
    private static func transform(_ value: Any, prompt: String, params: [String: String], seed: Int) -> Any {
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, sub) in dict {
                if (key == "seed" || key == "noise_seed"), isNumber(sub) {
                    // Bare numeric seed literal (no marker) → auto-randomise.
                    out[key] = seed
                } else {
                    out[key] = transform(sub, prompt: prompt, params: params, seed: seed)
                }
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { transform($0, prompt: prompt, params: params, seed: seed) }
        }
        if let string = value as? String {
            return resolveString(string, prompt: prompt, params: params, seed: seed)
        }
        return value
    }

    private static func resolveString(_ s: String, prompt: String, params: [String: String], seed: Int) -> Any {
        // Prompt first (may be embedded in a longer string).
        if s.contains(promptPlaceholder) {
            return s.replacingOccurrences(of: promptPlaceholder, with: prompt)
        }
        // A whole-value parameter marker becomes a typed value.
        if let name = wholeMarkerName(s), name != "prompt" {
            if name == "seed" { return seed }
            return coerce(params[name] ?? "")
        }
        return s
    }

    /// The parameter name when `s` is exactly one marker, else nil.
    private static func wholeMarkerName(_ s: String) -> String? {
        guard let match = try? wholeMarkerRegex.wholeMatch(in: s) else { return nil }
        return match.output[1].substring.map(String.init)
    }

    private static let wholeMarkerRegex = try! Regex("%([A-Za-z_][A-Za-z0-9_]*)(?:=[^%]*)?%")

    /// Int if it parses as one, else Double, else the raw string. Keeps
    /// numeric knobs numeric in the submitted JSON while leaving names
    /// (samplers, schedulers) as strings.
    private static func coerce(_ s: String) -> Any {
        if let i = Int(s) { return i }
        if let d = Double(s) { return d }
        return s
    }

    /// True for JSON numbers (NSNumber), excluding booleans — a `seed` field
    /// is never a bool, but guard anyway so we don't stomp a flag.
    private static func isNumber(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) != CFBooleanGetTypeID()
    }

    // MARK: - Submit

    /// Submits a prepared graph and returns the `prompt_id`.
    public func submit(graph: [String: Any], clientID: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "/prompt"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&request)
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["prompt": graph, "client_id": clientID]
        )

        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            // ComfyUI returns 400 with a `node_errors` body on invalid graphs.
            throw ComfyUIError.http(status: http.statusCode, body: Self.trimmedOrNil(data))
        }
        return try Self.parseSubmitResponse(data)
    }

    /// Extracts the `prompt_id`, or surfaces `node_errors` / `error` as a
    /// validation failure. Pure — unit-tested directly.
    public static func parseSubmitResponse(_ data: Data) throws -> String {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ComfyUIError.decoding(message: "réponse /prompt illisible")
        }
        if let nodeErrors = obj["node_errors"] as? [String: Any], !nodeErrors.isEmpty {
            throw ComfyUIError.validation(message: describe(nodeErrors))
        }
        if let error = obj["error"] {
            throw ComfyUIError.validation(message: describe(error))
        }
        guard let id = obj["prompt_id"] as? String, !id.isEmpty else {
            throw ComfyUIError.decoding(message: "prompt_id manquant")
        }
        return id
    }

    // MARK: - Poll + fetch

    /// Polls `/history/{id}` every second until an image is ready, then
    /// downloads it. Honours cancellation and a hard timeout.
    public func waitForImage(
        promptID: String,
        timeout: Duration = .seconds(300)
    ) async throws -> (data: Data, mimeType: String) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if let ref = try await pollHistoryOnce(promptID: promptID) {
                return try await fetchImage(ref)
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw ComfyUIError.timeout
    }

    private func pollHistoryOnce(promptID: String) async throws -> ImageRef? {
        var request = URLRequest(url: baseURL.appending(path: "/history/\(promptID)"))
        request.timeoutInterval = 15
        applyAuth(&request)
        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw ComfyUIError.http(status: http.statusCode, body: nil)
        }
        return Self.parseHistoryImage(data, promptID: promptID)
    }

    /// The first output image of a completed history entry, or nil while the
    /// job is still running. Pure — unit-tested directly. Node ids are sorted
    /// so a multi-SaveImage workflow picks deterministically.
    public static func parseHistoryImage(_ data: Data, promptID: String) -> ImageRef? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entry = root[promptID] as? [String: Any],
              let outputs = entry["outputs"] as? [String: Any]
        else { return nil }

        for key in outputs.keys.sorted() {
            guard let node = outputs[key] as? [String: Any],
                  let images = node["images"] as? [[String: Any]],
                  let first = images.first,
                  let filename = first["filename"] as? String
            else { continue }
            return ImageRef(
                filename: filename,
                subfolder: first["subfolder"] as? String ?? "",
                type: first["type"] as? String ?? "output"
            )
        }
        return nil
    }

    private func fetchImage(_ ref: ImageRef) async throws -> (data: Data, mimeType: String) {
        var components = URLComponents(
            url: baseURL.appending(path: "/view"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "filename", value: ref.filename),
            URLQueryItem(name: "subfolder", value: ref.subfolder),
            URLQueryItem(name: "type", value: ref.type)
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 60
        applyAuth(&request)
        let (data, http) = try await send(request)
        guard (200..<300).contains(http.statusCode) else {
            throw ComfyUIError.http(status: http.statusCode, body: nil)
        }
        return (data, Self.mimeType(forFilename: ref.filename))
    }

    public struct ImageRef: Equatable {
        public let filename: String
        public let subfolder: String
        public let type: String
    }

    public static func mimeType(forFilename name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "webp":        return "image/webp"
        default:            return "image/png"
        }
    }

    // MARK: - Helpers

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ComfyUIError.network(message: "réponse non-HTTP")
            }
            return (data, http)
        } catch let urlError as URLError {
            throw ComfyUIError.network(message: urlError.localizedDescription)
        }
    }

    private func applyAuth(_ request: inout URLRequest) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    }

    private static func trimmedOrNil(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func describe(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }
}
