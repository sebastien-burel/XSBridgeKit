import Foundation

/// Writes a text file inside one of the user's **writable** authorised folders
/// (a separate grant from read access — a folder authorised for reading is not
/// writable unless explicitly allowed). Paths that escape every writable root
/// (via `..` or symlinks) are rejected by `FileSpaceAccess`.
public struct WriteFileTool: Tool {
    public let roots: [AuthorizedRoot]

    public init(roots: [AuthorizedRoot]) {
        self.roots = roots
    }

    public let spec = ToolSpec(
        name: "write_file",
        description: """
        Writes UTF-8 text to a file inside one of the user's authorised
        writable folders (creating parent directories as needed). By default it
        overwrites; set append=true to append. The path must be absolute and
        inside an authorised folder.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Absolute path of the file to write." },
            "content": { "type": "string", "description": "Text to write." },
            "append": { "type": "boolean", "description": "Append instead of overwrite (default false)." }
          },
          "required": ["path", "content"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let path: String
        let content: String
        let append: Bool?
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            throw ToolError.invalidArguments(
                reason: "expected {path: string, content: string, append?: bool}")
        }
        return try FileSpaceAccess.withScopedAccess(to: args.path, roots: roots) { url in
            let fm = FileManager.default
            try fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = Data(args.content.utf8)
            if args.append == true, let existing = try? Data(contentsOf: url) {
                try (existing + bytes).write(to: url)
            } else {
                try bytes.write(to: url)
            }
            return "wrote \(bytes.count) bytes to \(url.path)"
        }
    }
}
