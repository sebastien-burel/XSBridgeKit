import Foundation
import KaozJSCore

/// Locates the bundled JS module files (`Resources/js`) that make up the
/// JS-first runtime — providers, the XMLHttpRequest shim, and the orchestrators.
/// They ship as real ES modules and are loaded at run time via `import()` of
/// their absolute bundle path.
enum JSResource {
    /// The `js` resource directory inside this package's bundle, or nil if the
    /// resources were not bundled (a build misconfiguration).
    static let directory: URL? = Bundle.module.url(forResource: "js", withExtension: nil)

    /// Registers this bundle's JS directory as a trusted module prefix, exactly
    /// once. Module roots are process-wide, so a confined agent's roots also
    /// govern the framework's own engines (a JS provider, a sub-agent's
    /// orchestrator) which import these modules by absolute path. Marking the
    /// directory trusted keeps those imports working while still blocking an
    /// agent's arbitrary absolute imports. Referenced from every engine factory;
    /// the `static let` runs its initializer once.
    static let registerTrustedPrefix: Void = {
        if let dir = directory?.path { xsBridgeAddTrustedModulePrefix(dir) }
    }()

    /// Absolute filesystem path of a bundled `<name>.js` module, for `import()`.
    static func path(_ name: String) -> String? {
        directory?.appendingPathComponent("\(name).js").path
    }

    /// A JS statement that dynamically imports the named module for its side
    /// effects (installing globals). `import()` resolves within the eval's
    /// promise-drain, so globals are set by the time `eval` returns.
    static func importStatement(_ name: String) -> String? {
        path(name).map { "import(\(AgentJSON.jsLiteral($0)));" }
    }
}
