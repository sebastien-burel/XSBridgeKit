import Foundation

/// Gatekeeper for the file tools. Every path an LLM hands us is validated
/// against the user's authorised roots before any file operation runs, so a
/// model can't read outside the folders the user explicitly granted — even via
/// `..` traversal or symlinks. Comparison happens on symlink-resolved,
/// standardised paths to close both holes.
public enum FileSpaceAccess {

    /// The root whose folder contains `requested`, or nil if the path escapes
    /// every authorised root.
    public static func containingRoot(
        for requested: URL,
        in roots: [AuthorizedRoot]
    ) -> AuthorizedRoot? {
        let target = canonical(requested).pathComponents
        for root in roots {
            let base = canonical(root.url).pathComponents
            guard target.count >= base.count else { continue }
            if Array(target.prefix(base.count)) == base {
                return root
            }
        }
        return nil
    }

    /// Resolves `..`, `.` and symlinks so the prefix check can't be fooled.
    public static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Runs `body` with the security scope of the root containing `path`
    /// active, passing the canonicalised URL. Throws if the path is outside
    /// every authorised root.
    public static func withScopedAccess<T>(
        to path: String,
        roots: [AuthorizedRoot],
        _ body: (URL) throws -> T
    ) throws -> T {
        let requested = URL(fileURLWithPath: path)
        guard let root = containingRoot(for: requested, in: roots) else {
            throw ToolError.invalidArguments(
                reason: "le chemin « \(path) » est hors des dossiers autorisés"
            )
        }
        let didStart = root.url.startAccessingSecurityScopedResource()
        defer { if didStart { root.url.stopAccessingSecurityScopedResource() } }
        return try body(canonical(requested))
    }
}
