import Foundation

/// A user-supplied plugin: a JSON manifest describing one or more tools backed
/// by HTTP endpoints. The model only ever controls the *arguments* — the URL,
/// method and headers are fixed by whoever authored the manifest, so a model
/// can't point a request at an arbitrary host.
public struct PluginManifest: Equatable {
    public let name: String
    public let description: String?
    public let tools: [PluginToolDef]
}

public struct PluginToolDef: Equatable {
    public enum Method: String {
        case get = "GET"
        case post = "POST"
    }

    public let name: String
    public let description: String
    public let inputSchemaJSON: String
    /// URL with two kinds of placeholder: `{arg}` filled from the model's tool
    /// arguments (path/query templating), and `***SECRET***` filled from the
    /// Keychain. Stored as a string because templated URLs aren't valid `URL`s
    /// until substituted.
    let urlTemplate: String
    let method: Method
    let headers: [String: String]

    /// Secret placeholder names (`***NAME***`) referenced in this tool's URL
    /// or headers. These are filled by the user and stored in the Keychain,
    /// never in the manifest.
    public var secretNames: Set<String> {
        var names = PluginSecrets.placeholders(in: urlTemplate)
        for value in headers.values {
            names.formUnion(PluginSecrets.placeholders(in: value))
        }
        return names
    }
}

public enum PluginError: Error, LocalizedError, Equatable {
    case invalidJSON
    case missingField(String)
    case noTools
    case invalidURL(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:           return "Le fichier n'est pas un JSON valide."
        case .missingField(let f):   return "Champ manquant ou invalide : « \(f) »."
        case .noTools:               return "Le manifeste ne déclare aucun outil."
        case .invalidURL(let u):     return "URL invalide (http/https requis) : \(u)."
        }
    }
}

extension PluginManifest {
    /// Parses and validates a manifest. Uses JSONSerialization (not Codable)
    /// so each tool's `input_schema` can be re-serialised verbatim into the
    /// raw JSON string our ToolSpec carries.
    public init(data: Data) throws {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw PluginError.invalidJSON
        }
        guard let name = root["name"] as? String, !name.isEmpty else {
            throw PluginError.missingField("name")
        }
        guard let rawTools = root["tools"] as? [[String: Any]], !rawTools.isEmpty else {
            throw PluginError.noTools
        }

        self.name = name
        self.description = root["description"] as? String
        self.tools = try rawTools.map { try PluginToolDef(dictionary: $0) }
    }
}

extension PluginToolDef {
    init(dictionary dict: [String: Any]) throws {
        guard let name = dict["name"] as? String, !name.isEmpty else {
            throw PluginError.missingField("tools[].name")
        }
        guard let description = dict["description"] as? String, !description.isEmpty else {
            throw PluginError.missingField("tools[].description")
        }
        guard let schema = dict["input_schema"] as? [String: Any],
              let schemaData = try? JSONSerialization.data(withJSONObject: schema),
              let schemaJSON = String(data: schemaData, encoding: .utf8) else {
            throw PluginError.missingField("tools[].input_schema")
        }
        guard let urlString = dict["url"] as? String else {
            throw PluginError.missingField("tools[].url")
        }
        // The template may contain {arg}/***SECRET*** placeholders, so it
        // isn't necessarily a parseable URL yet — validate the scheme by
        // prefix instead.
        let lower = urlString.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            throw PluginError.invalidURL(urlString)
        }

        let method = (dict["method"] as? String).flatMap { Method(rawValue: $0.uppercased()) } ?? .post
        let headers = (dict["headers"] as? [String: String]) ?? [:]

        self.name = name
        self.description = description
        self.inputSchemaJSON = schemaJSON
        self.urlTemplate = urlString
        self.method = method
        self.headers = headers
    }
}
