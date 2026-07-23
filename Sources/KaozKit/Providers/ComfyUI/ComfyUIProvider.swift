import Foundation

/// Text-to-image provider backed by a local ComfyUI server. Each "model" is
/// a named workflow (ComfyUI API-format JSON) the user pasted in settings.
/// The last user message becomes the prompt (injected at the `%prompt%`
/// marker); the rendered image comes back as a single `.imageOutput`.
public struct ComfyUIProvider: LLMProvider {
    public let id: String = "comfyui"
    public let displayName: String = "ComfyUI"

    public let baseURL: URL
    public let apiKey: String
    public let workflowName: String
    public let workflowJSON: String
    /// User-set values for the workflow's `%name%` markers (settings).
    /// A `seed` value that isn't a number means "randomise each run".
    public let params: [String: String]

    private let client: ComfyUIClient

    public init(
        baseURL: URL,
        apiKey: String,
        workflowName: String,
        workflowJSON: String,
        params: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.workflowName = workflowName
        self.workflowJSON = workflowJSON
        self.params = params
        self.client = ComfyUIClient(baseURL: baseURL, apiKey: apiKey, session: session)
    }

    public func availability() async -> ProviderAvailability {
        guard workflowJSON.contains(ComfyUIClient.promptPlaceholder) else {
            return .unavailable(
                reason: "Le workflow « \(workflowName) » ne contient pas le marqueur \(ComfyUIClient.promptPlaceholder)."
            )
        }
        if await client.systemStatsReachable() { return .ready }
        return .unavailable(reason: "Serveur ComfyUI injoignable à \(baseURL.absoluteString).")
    }

    public func chat(messages: [ChatMessage], tools: [ToolSpec]) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let prompt = messages.last { $0.role == .user }?.content ?? ""
                    // A numeric `seed` param reproduces; anything else (empty /
                    // "random") gets a fresh seed so identical prompts vary.
                    let seed = (params["seed"]).flatMap(Int.init) ?? Int.random(in: 0...4_294_967_295)
                    let graph = try ComfyUIClient.prepareWorkflow(
                        json: workflowJSON, prompt: prompt, params: params, seed: seed
                    )
                    let promptID = try await client.submit(graph: graph, clientID: UUID().uuidString)
                    let image = try await client.waitForImage(promptID: promptID)
                    continuation.yield(.imageOutput(data: image.data, mimeType: image.mimeType))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
