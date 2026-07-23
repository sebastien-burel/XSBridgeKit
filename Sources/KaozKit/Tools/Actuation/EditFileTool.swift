import Foundation

/// Replaces text in a file inside one of the user's authorised **writable**
/// folders. `old_string` must be present; by default the first occurrence is
/// replaced (set replace_all=true for every one). Confined like write_file.
public struct EditFileTool: Tool {
    public let roots: [AuthorizedRoot]

    public init(roots: [AuthorizedRoot]) {
        self.roots = roots
    }

    public let spec = ToolSpec(
        name: "edit_file",
        description: """
        Edits an existing text file inside an authorised writable folder by
        replacing old_string with new_string. Fails if old_string is not found.
        Replaces the first occurrence unless replace_all=true.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "path": { "type": "string", "description": "Absolute path of the file to edit." },
            "old_string": { "type": "string", "description": "Exact text to replace." },
            "new_string": { "type": "string", "description": "Replacement text." },
            "replace_all": { "type": "boolean", "description": "Replace every occurrence (default false)." }
          },
          "required": ["path", "old_string", "new_string"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let path: String
        let oldString: String
        let newString: String
        let replaceAll: Bool?
        enum CodingKeys: String, CodingKey {
            case path
            case oldString = "old_string"
            case newString = "new_string"
            case replaceAll = "replace_all"
        }
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            throw ToolError.invalidArguments(
                reason: "expected {path, old_string, new_string, replace_all?}")
        }
        return try FileSpaceAccess.withScopedAccess(to: args.path, roots: roots) { url in
            guard var content = try? String(contentsOf: url, encoding: .utf8) else {
                throw ToolError.execution(message: "cannot read « \(url.path) » as UTF-8 text")
            }
            guard content.contains(args.oldString) else {
                throw ToolError.execution(message: "old_string not found in « \(url.path) »")
            }
            if args.replaceAll == true {
                content = content.replacingOccurrences(of: args.oldString, with: args.newString)
            } else if let range = content.range(of: args.oldString) {
                content.replaceSubrange(range, with: args.newString)
            }
            try Data(content.utf8).write(to: url)
            return "edited \(url.path)"
        }
    }
}
