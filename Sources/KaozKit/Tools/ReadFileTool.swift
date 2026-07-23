import Foundation

/// Reads a UTF-8 text file inside one of the user's authorised folders and
/// returns its content, capped so a large file can't blow the model's context.
public struct ReadFileTool: Tool {
    public let roots: [AuthorizedRoot]

    public init(roots: [AuthorizedRoot]) {
        self.roots = roots
    }

    private static let defaultMaxBytes = 50_000
    private static let hardMaxBytes = 500_000

    public let spec = ToolSpec(
        name: "read_file",
        description: """
        Reads the text content of a file inside one of the user's authorised
        local folders. Use list_directory first to find the absolute path. The
        result is capped at max_bytes bytes (default 50000). Read-only;
        non-text files are rejected.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Absolute path of the file to read."
            },
            "max_bytes": {
              "type": "integer",
              "description": "Maximum number of bytes to return (default 50000).",
              "minimum": 1,
              "maximum": 500000
            }
          },
          "required": ["path"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let path: String
        let maxBytes: Int?

        enum CodingKeys: String, CodingKey {
            case path
            case maxBytes = "max_bytes"
        }
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            let raw = String(data: arguments, encoding: .utf8) ?? "<binary>"
            throw ToolError.invalidArguments(
                reason: "expected {path: string, max_bytes?: int}, got: \(raw)"
            )
        }

        let limit = min(args.maxBytes ?? Self.defaultMaxBytes, Self.hardMaxBytes)

        return try FileSpaceAccess.withScopedAccess(to: args.path, roots: roots) { url in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ToolError.execution(message: "introuvable : \(args.path)")
            }
            guard !isDir.boolValue else {
                throw ToolError.execution(message: "est un dossier, pas un fichier : \(args.path)")
            }

            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ToolError.execution(message: "lecture impossible : \(error.localizedDescription)")
            }

            let slice = data.prefix(limit)
            guard let text = String(data: slice, encoding: .utf8) else {
                throw ToolError.execution(message: "fichier non textuel (UTF-8) : \(args.path)")
            }
            return data.count > limit ? text + "\n[tronqué]" : text
        }
    }
}
