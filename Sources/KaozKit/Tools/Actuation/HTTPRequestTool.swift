import Foundation

/// Makes an outbound HTTP request (any method) and returns { status, body }.
/// This is the universal **outbound channel**: an agent posts to a Slack /
/// Telegram / Discord webhook or any REST API. Opt-in and, optionally, host-
/// restricted (an allowlist mitigates SSRF to internal services). Distinct from
/// the read-only `fetch_url` tool (GET + HTML-strip): this one sends bodies and
/// headers and returns the raw response.
public struct HTTPRequestTool: Tool {
    /// nil = any host allowed; otherwise the request host must match one of these.
    public let allowedHosts: [String]?
    private static let maxBodyBytes = 200_000

    public init(allowedHosts: [String]? = nil) {
        self.allowedHosts = allowedHosts
    }

    public let spec = ToolSpec(
        name: "http_request",
        description: """
        Sends an HTTP request and returns { status, body }. Use it to call REST
        APIs or post to webhooks (Slack/Telegram/Discord/…). method defaults to
        GET; headers and body are optional. The body is returned as text, capped.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "url": { "type": "string", "description": "Absolute http(s) URL." },
            "method": { "type": "string", "description": "GET, POST, PUT, … (default GET)." },
            "headers": { "type": "object", "description": "Header name → value.", "additionalProperties": { "type": "string" } },
            "body": { "type": "string", "description": "Request body (for POST/PUT/…)." }
          },
          "required": ["url"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let url: String
        let method: String?
        let headers: [String: String]?
        let body: String?
    }

    public func execute(arguments: Data) async throws -> String {
        guard let args = try? JSONDecoder().decode(Args.self, from: arguments) else {
            throw ToolError.invalidArguments(reason: "expected {url, method?, headers?, body?}")
        }
        guard let url = URL(string: args.url), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw ToolError.invalidArguments(reason: "url must be an absolute http(s) URL")
        }
        if let allowedHosts, let host = url.host,
           !allowedHosts.contains(where: { $0.caseInsensitiveCompare(host) == .orderedSame }) {
            throw ToolError.execution(message: "host « \(host) » is not in the allowed list")
        }

        var request = URLRequest(url: url)
        request.httpMethod = (args.method ?? "GET").uppercased()
        for (k, v) in args.headers ?? [:] {
            let clean = v.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            request.setValue(clean, forHTTPHeaderField: k)
        }
        if let body = args.body { request.httpBody = Data(body.utf8) }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let capped = data.prefix(Self.maxBodyBytes)
            let text = String(data: capped, encoding: .utf8) ?? ""
            let result: [String: Any] = ["status": status, "body": text]
            let json = (try? JSONSerialization.data(withJSONObject: result))
                .flatMap { String(data: $0, encoding: .utf8) }
            return json ?? text
        } catch {
            throw ToolError.execution(message: "http_request failed: \(error.localizedDescription)")
        }
    }
}
