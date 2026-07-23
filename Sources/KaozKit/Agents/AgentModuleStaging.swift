import Foundation

/// Materializes an agent run's module graph on disk so the XS engine's
/// filesystem module loader can import it. The agent script is written as
/// `agent.js`, and the user's chosen libraries folder (the confinement
/// boundary) is copied next to it so relative imports (`./util.js`) resolve.
///
/// Confinement note: only files under `libraryRoot` are copied, so relative
/// imports can't escape it; absolute-path imports (`import "/…"`) are NOT
/// blocked by the engine's loader (accepted tradeoff — see the migration plan).
/// The staging dir is removed after the run.
public nonisolated struct AgentModuleStaging {
    public let root: URL
    /// Absolute path of the staged agent module (import target).
    public let agentPath: String

    public init(agentSource: String, libraryRoot: URL?) throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "tykaoz-agent-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        if let lib = libraryRoot?.standardizedFileURL,
           let items = try? fm.contentsOfDirectory(
               at: lib, includingPropertiesForKeys: nil) {
            for item in items {
                try? fm.copyItem(at: item, to: root.appending(path: item.lastPathComponent))
            }
        }

        let agentURL = root.appending(path: "agent.js")
        try agentSource.write(to: agentURL, atomically: true, encoding: .utf8)

        self.root = root
        self.agentPath = agentURL.path
    }

    public func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
