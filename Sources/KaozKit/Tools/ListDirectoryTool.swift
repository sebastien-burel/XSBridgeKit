import Foundation

/// Lists the entries of a directory inside one of the user's authorised
/// folders. Called with no path it enumerates the authorised roots themselves,
/// letting the model discover where it's allowed to look.
public struct ListDirectoryTool: Tool {
    public let roots: [AuthorizedRoot]

    public init(roots: [AuthorizedRoot]) {
        self.roots = roots
    }

    public let spec = ToolSpec(
        name: "list_directory",
        description: """
        Lists files and subfolders inside one of the user's authorised local
        folders. Call without a path to discover the authorised root folders
        and their absolute paths; then call with an absolute path to inspect a
        directory. Set recursive to true to get the whole subtree in one call
        (paths are shown relative to the listed directory) instead of having to
        descend folder by folder. Read-only.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "path": {
              "type": "string",
              "description": "Absolute path of the directory to list. Omit to list the authorised roots."
            },
            "recursive": {
              "type": "boolean",
              "description": "List the full subtree in one call (default false)."
            }
          },
          "additionalProperties": false
        }
        """
    )

    private static let maxEntries = 1000

    private struct Args: Decodable {
        let path: String?
        let recursive: Bool?
    }

    public func execute(arguments: Data) async throws -> String {
        let args = (try? JSONDecoder().decode(Args.self, from: arguments))
            ?? Args(path: nil, recursive: nil)

        guard let path = args.path, !path.trimmingCharacters(in: .whitespaces).isEmpty else {
            return listRoots()
        }

        return try FileSpaceAccess.withScopedAccess(to: path, roots: roots) { url in
            let fm = FileManager.default
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
                throw ToolError.execution(message: "introuvable : \(path)")
            }
            guard isDir.boolValue else {
                throw ToolError.execution(message: "n'est pas un dossier : \(path)")
            }
            return args.recursive == true
                ? Self.listRecursive(url, fm: fm)
                : try Self.listShallow(url, fm: fm)
        }
    }

    private static func listShallow(_ url: URL, fm: FileManager) throws -> String {
        let entries = try fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        if entries.isEmpty { return "(dossier vide)" }

        let lines = entries
            .sorted { $0.lastPathComponent.localizedCompare($1.lastPathComponent) == .orderedAscending }
            .prefix(maxEntries)
            .map { entry -> String in
                let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    return "\(entry.lastPathComponent)/"
                }
                return "\(entry.lastPathComponent)\t\(values?.fileSize ?? 0) o"
            }
        let suffix = entries.count > maxEntries ? "\n… (\(entries.count - maxEntries) de plus)" : ""
        return lines.joined(separator: "\n") + suffix
    }

    /// Walks the subtree once and returns paths relative to `base`, so the
    /// model sees the whole structure without descending folder by folder.
    private static func listRecursive(_ base: URL, fm: FileManager) -> String {
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return "(dossier vide)" }

        let basePath = base.path
        var lines: [String] = []
        var truncated = false
        for case let entry as URL in enumerator {
            if lines.count >= maxEntries { truncated = true; break }
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            var relative = entry.path
            if relative.hasPrefix(basePath) {
                relative = String(relative.dropFirst(basePath.count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            if values?.isDirectory == true {
                lines.append("\(relative)/")
            } else {
                lines.append("\(relative)\t\(values?.fileSize ?? 0) o")
            }
        }
        if lines.isEmpty { return "(dossier vide)" }
        lines.sort()
        return lines.joined(separator: "\n") + (truncated ? "\n… (résultat limité à \(maxEntries) entrées)" : "")
    }

    private func listRoots() -> String {
        guard !roots.isEmpty else {
            return "Aucun dossier autorisé. L'utilisateur peut en ajouter dans les réglages."
        }
        return "Dossiers autorisés :\n" + roots
            .map { "\($0.name)\t\($0.url.path)" }
            .joined(separator: "\n")
    }
}
