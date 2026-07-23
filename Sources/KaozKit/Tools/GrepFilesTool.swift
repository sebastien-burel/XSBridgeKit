import Foundation

/// Searches for a pattern across the text files of one authorised folder (or
/// all of them) and returns matching lines as `path:line: text`. The pattern
/// is treated as a regular expression, falling back to a literal substring if
/// it isn't valid regex. Output is capped to keep the model's context sane.
public struct GrepFilesTool: Tool {
    public let roots: [AuthorizedRoot]

    public init(roots: [AuthorizedRoot]) {
        self.roots = roots
    }

    private static let defaultMaxResults = 50
    private static let hardMaxResults = 500
    private static let maxFileBytes = 2_000_000

    public let spec = ToolSpec(
        name: "grep_files",
        description: """
        Searches the text files inside the user's authorised local folders for
        a pattern and returns matching lines as "path:line: text". The pattern
        is a regular expression (falls back to a literal substring if invalid).
        Provide a path to limit the search to one directory, otherwise all
        authorised roots are searched. Read-only.
        """,
        inputSchemaJSON: """
        {
          "type": "object",
          "properties": {
            "pattern": {
              "type": "string",
              "description": "Regular expression (or literal text) to search for."
            },
            "path": {
              "type": "string",
              "description": "Absolute path of a directory to limit the search. Omit to search all authorised roots."
            },
            "max_results": {
              "type": "integer",
              "description": "Maximum number of matching lines to return (default 50).",
              "minimum": 1,
              "maximum": 500
            }
          },
          "required": ["pattern"],
          "additionalProperties": false
        }
        """
    )

    private struct Args: Decodable {
        let pattern: String
        let path: String?
        let maxResults: Int?

        enum CodingKeys: String, CodingKey {
            case pattern, path
            case maxResults = "max_results"
        }
    }

    public func execute(arguments: Data) async throws -> String {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: arguments)
        } catch {
            let raw = String(data: arguments, encoding: .utf8) ?? "<binary>"
            throw ToolError.invalidArguments(
                reason: "expected {pattern: string, path?: string, max_results?: int}, got: \(raw)"
            )
        }
        guard !args.pattern.isEmpty else {
            throw ToolError.invalidArguments(reason: "pattern ne peut pas être vide")
        }

        let limit = min(args.maxResults ?? Self.defaultMaxResults, Self.hardMaxResults)
        let matcher = Matcher(pattern: args.pattern)

        if let path = args.path, !path.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = try FileSpaceAccess.withScopedAccess(to: path, roots: roots) { url in
                search(in: url, matcher: matcher, limit: limit)
            }
            return format(matches, limit: limit)
        }

        guard !roots.isEmpty else {
            throw ToolError.execution(message: "aucun dossier autorisé")
        }
        var all: [String] = []
        for root in roots {
            let didStart = root.url.startAccessingSecurityScopedResource()
            defer { if didStart { root.url.stopAccessingSecurityScopedResource() } }
            all += search(in: root.url, matcher: matcher, limit: limit - all.count)
            if all.count >= limit { break }
        }
        return format(all, limit: limit)
    }

    // MARK: - Search

    private func search(in directory: URL, matcher: Matcher, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var matches: [String] = []
        for case let fileURL as URL in enumerator {
            if matches.count >= limit { break }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? 0) <= Self.maxFileBytes,
                  let data = try? Data(contentsOf: fileURL),
                  let text = String(data: data, encoding: .utf8)
            else { continue }

            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if matches.count >= limit { break }
                if matcher.matches(String(line)) {
                    matches.append("\(fileURL.path):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return matches
    }

    private func format(_ matches: [String], limit: Int) -> String {
        if matches.isEmpty { return "Aucune correspondance." }
        let capped = matches.prefix(limit)
        let suffix = matches.count > limit ? "\n… (au moins \(limit) correspondances, résultat limité)" : ""
        return capped.joined(separator: "\n") + suffix
    }

    /// Compiles the pattern as regex once, falling back to a case-insensitive
    /// literal substring when the pattern isn't valid regex.
    private struct Matcher {
        let regex: NSRegularExpression?
        let literal: String

        init(pattern: String) {
            self.regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            self.literal = pattern
        }

        func matches(_ line: String) -> Bool {
            if let regex {
                let range = NSRange(line.startIndex..., in: line)
                return regex.firstMatch(in: line, range: range) != nil
            }
            return line.range(of: literal, options: .caseInsensitive) != nil
        }
    }
}
