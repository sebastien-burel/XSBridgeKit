import Foundation

/// Resolves ES module specifiers for a running JS agent to source text.
///
/// The agent script itself is served under the reserved id `@agent`. Every other
/// specifier resolves to a `.js` / `.mjs` / `.json` file under the user's chosen
/// libraries folder, and resolution is **confined** to that folder: a specifier
/// that escapes it (via `../`, an absolute path) is rejected.
///
/// Pure and synchronous — `find` / `load` run on the XS engine thread while the
/// agent `import`s. The caller holds the folder's security scope for the run.
public nonisolated struct ModuleResolver: Sendable {
    /// Reserved id for the agent script (the entry module).
    public static let entryID = "@agent"

    public let entrySource: String
    /// Standardized libraries root, or nil when the user hasn't chosen one.
    public let root: URL?

    public init(entrySource: String, root: URL?) {
        self.entrySource = entrySource
        self.root = root?.standardizedFileURL
    }

    /// (specifier, importer id) → canonical module id (an absolute file path),
    /// or nil when it can't be resolved inside the libraries folder. Node-style
    /// resolution: tries the path as given, then `+.js`, `+.mjs`, `/index.js`.
    public func find(specifier: String, importer: String?) -> String? {
        if specifier == Self.entryID { return Self.entryID }
        guard let root else { return nil }

        // Relative specifiers resolve against the importing module's folder;
        // bare specifiers (and the entry's imports) resolve against the root.
        let isRelative = specifier.hasPrefix("./") || specifier.hasPrefix("../")
        let base: URL
        if isRelative, let importer, importer != Self.entryID {
            base = URL(fileURLWithPath: importer).deletingLastPathComponent()
        } else {
            base = root
        }

        let path = URL(fileURLWithPath: specifier, relativeTo: base).standardizedFileURL.path
        for candidate in [path, path + ".js", path + ".mjs", path + "/index.js"] {
            let url = URL(fileURLWithPath: candidate).standardizedFileURL
            guard isInside(url) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                return url.path
            }
        }
        return nil
    }

    /// Module id → source. `@agent` returns the agent script; any other id is a
    /// file path produced by `find`, re-checked for confinement before reading.
    public func load(id: String) -> String? {
        if id == Self.entryID { return entrySource }
        let url = URL(fileURLWithPath: id).standardizedFileURL
        guard isInside(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    private func isInside(_ url: URL) -> Bool {
        guard let root else { return false }
        return url.path == root.path || url.path.hasPrefix(root.path + "/")
    }
}
