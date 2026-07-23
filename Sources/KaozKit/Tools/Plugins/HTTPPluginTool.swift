import Foundation

/// Bridges a plugin's tool definition to the `Tool` protocol. When invoked it
/// calls the configured HTTP endpoint — POST sends the arguments as the JSON
/// body, GET maps them to query items — and returns the response body as text.
public struct HTTPPluginTool: Tool {
    let definition: PluginToolDef
    let secrets: [String: String]
    let session: URLSession

    public init(definition: PluginToolDef, secrets: [String: String] = [:], session: URLSession = .shared) {
        self.definition = definition
        self.secrets = secrets
        self.session = session
    }

    private static let maxResponseChars = 100_000

    public var spec: ToolSpec {
        ToolSpec(
            name: definition.name,
            description: definition.description,
            inputSchemaJSON: definition.inputSchemaJSON
        )
    }

    public func execute(arguments: Data) async throws -> String {
        let request = try buildRequest(arguments: arguments)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw ToolError.execution(message: "erreur réseau : \(urlError.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw ToolError.execution(message: "réponse non-HTTP")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            let snippet = body.prefix(500)
            throw ToolError.execution(message: "HTTP \(http.statusCode)\(snippet.isEmpty ? "" : " : \(snippet)")")
        }

        return body.count > Self.maxResponseChars
            ? String(body.prefix(Self.maxResponseChars)) + "\n[tronqué]"
            : body
    }

    private func buildRequest(arguments: Data) throws -> URLRequest {
        let argDict = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] ?? [:]
        let (resolvedURL, usedKeys) = try self.resolvedURL(arguments: argDict)

        switch definition.method {
        case .post:
            var request = URLRequest(url: resolvedURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = arguments.isEmpty ? Data("{}".utf8) : arguments
            applyHeaders(&request)
            request.timeoutInterval = 30
            return request

        case .get:
            guard var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) else {
                throw ToolError.execution(message: "URL invalide")
            }
            // Append only the arguments not already consumed by {placeholders}
            // in the URL path/query.
            let items = argDict
                .filter { !usedKeys.contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: Self.stringify($0.value)) }
            if !items.isEmpty {
                components.queryItems = (components.queryItems ?? []) + items
            }
            guard let url = components.url else {
                throw ToolError.execution(message: "construction d'URL impossible")
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            applyHeaders(&request)
            request.timeoutInterval = 30
            return request
        }
    }

    /// Substitutes secret then argument placeholders in the URL template and
    /// returns the resulting URL plus the argument names consumed by it.
    private func resolvedURL(arguments: [String: Any]) throws -> (URL, Set<String>) {
        let withSecrets = PluginSecrets.substitute(in: definition.urlTemplate, secrets: secrets)
        let (filled, usedKeys) = PluginArguments.substitute(in: withSecrets, arguments: arguments)
        guard let url = URL(string: filled) else {
            throw ToolError.execution(message: "URL invalide après substitution : \(filled)")
        }
        return (url, usedKeys)
    }

    private func applyHeaders(_ request: inout URLRequest) {
        for (key, value) in definition.headers {
            request.setValue(
                PluginSecrets.substitute(in: value, secrets: secrets),
                forHTTPHeaderField: key
            )
        }
    }

    /// JSONSerialization hands us NSNumber for every numeric/bool; `as? Bool`
    /// then matches *any* NSNumber whose value is 0 or 1 (the bridging trap),
    /// so we must check the underlying CF type to tell `true` from `1`.
    private static func stringify(_ value: Any) -> String {
        if let s = value as? String { return s }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "true" : "false"
            }
            return number.stringValue
        }
        return String(describing: value)
    }
}
