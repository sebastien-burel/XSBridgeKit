import Foundation
import KaozJS
import KaozHostC

/// Loads a JavaScript script that declares `globalThis.tools = [{ name,
/// description, input_schema, run: async (args) => … }]` and exposes each entry
/// as a native `Tool`, so a JS-authored tool slots into the existing
/// `ToolRegistry` alongside built-in and HTTP-plugin tools.
///
/// One persistent engine backs the whole bundle (shared by its tools). Tools
/// can themselves reach the LLM, other tools and memory via `host.*`, since the
/// bundle wires the same `TyKaozHost`.
public nonisolated final class JSToolBundle: @unchecked Sendable {

    private let engine: XSEngine
    private let host: TyKaozHost
    private let lock = NSLock()
    private var waiters: [String: (Result<String, Error>) -> Void] = [:]

    /// The tool specs declared by the script, read once at load.
    public let specs: [ToolSpec]

    /// - Parameters:
    ///   - script: JS that declares `globalThis.tools = [{ name, description,
    ///     input_schema, run }]` (a plain script, or a bootstrap that imports
    ///     ES modules and pushes their defaults).
    ///   - installHTTP: install the native `__http` primitive so tools can use
    ///     the `XMLHttpRequest` shim (HTTP tools).
    ///   - config: exposed to the tools as `globalThis.__toolConfig` (e.g. API keys).
    public init?(
        script: String,
        installHTTP: Bool = false,
        config: [String: Any] = [:],
        makeProvider: @escaping @Sendable () -> (any LLMProvider)? = { nil },
        tools: ToolRegistry,
        memory: MemoryStoring,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let host = TyKaozHost(
            makeProvider: makeProvider, tools: tools, memory: memory, log: log)
        guard let engine = XSEngine.tyKaoz(host: host) else { return nil }
        self.host = host
        self.engine = engine
        if installHTTP {
            engine.withMachine { xsBridgeHttpInstall($0) }
        }

        do {
            if !config.isEmpty {
                _ = try engine.eval("globalThis.__toolConfig = \(AgentJSON.string(config));")
            }
            _ = try engine.eval(script)
            let specsJSON = try engine.eval(
                "(globalThis.tools||[]).map(function(t){"
                + "return {name:t.name,description:t.description,input_schema:t.input_schema};})")
            self.specs = JSToolBundle.parseSpecs(specsJSON)
        } catch {
            return nil
        }

        host.onToolResult = { [weak self] params in self?.deliver(params) }
    }

    /// Load JS tools that ship as bundled ES modules (`Resources/js/tools/<name>.js`,
    /// each `export default { name, description, input_schema, run }`). Installs
    /// `__http` so HTTP tools can use the `XMLHttpRequest` shim.
    public convenience init?(
        toolModules names: [String],
        config: [String: Any] = [:],
        makeProvider: @escaping @Sendable () -> (any LLMProvider)? = { nil },
        tools: ToolRegistry,
        memory: MemoryStoring,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        let paths = names.compactMap { JSResource.path("tools/\($0)") }
        guard paths.count == names.count else { return nil }
        let imports = paths.map { "import(\(AgentJSON.jsLiteral($0)))" }.joined(separator: ", ")
        // Dynamic imports resolve within eval's drain, so globalThis.tools is
        // populated by the time init reads the specs.
        let bootstrap = """
        globalThis.tools = [];
        globalThis.__toolsReady = (async function () {
            const mods = await Promise.all([\(imports)]);
            for (const m of mods) globalThis.tools.push(m.default);
        })();
        """
        self.init(script: bootstrap, installHTTP: true, config: config,
                  makeProvider: makeProvider, tools: tools, memory: memory, log: log)
    }

    /// The native `Tool` wrappers for each declared tool.
    public func tools() -> [any Tool] {
        specs.map { JSBackedTool(spec: $0, bundle: self) }
    }

    /// Invoke a declared tool and await its result. Called from `Tool.execute`.
    public func call(name: String, argsJSON: String) async throws -> String {
        let callId = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            waiters[callId] = { continuation.resume(with: $0) }
            lock.unlock()

            let invoke = "__callTool("
                + "\(AgentJSON.jsLiteral(name)), "
                + "\(AgentJSON.jsLiteral(argsJSON)), "
                + "\(AgentJSON.jsLiteral(callId)))"
            do {
                _ = try engine.eval(invoke)
            } catch let error as XSError {
                resolveWaiter(callId, .failure(ToolError.execution(message: error.message)))
            } catch {
                resolveWaiter(callId, .failure(error))
            }
        }
    }

    // MARK: - Result delivery

    /// `__toolResult` params: `[callId, resultJSON | null, errorMessage | null]`.
    private func deliver(_ params: [Any]) {
        guard let callId = params.first as? String else { return }
        if params.count > 2, let message = params[2] as? String, !message.isEmpty {
            resolveWaiter(callId, .failure(ToolError.execution(message: message)))
            return
        }
        let raw = (params.count > 1 ? params[1] as? String : nil) ?? "null"
        resolveWaiter(callId, .success(AgentJSON.unwrapResult(raw)))
    }

    private func resolveWaiter(_ id: String, _ result: Result<String, Error>) {
        lock.lock()
        let waiter = waiters.removeValue(forKey: id)
        lock.unlock()
        waiter?(result)
    }

    private static func parseSpecs(_ json: String) -> [ToolSpec] {
        guard let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let description = (entry["description"] as? String) ?? ""
            let schema = entry["input_schema"].map { AgentJSON.string($0) } ?? "{}"
            return ToolSpec(name: name, description: description, inputSchemaJSON: schema)
        }
    }
}

/// A native `Tool` whose execution is delegated to a JS `run` function in a
/// `JSToolBundle`.
public nonisolated struct JSBackedTool: Tool {
    public let spec: ToolSpec
    public let bundle: JSToolBundle

    public func execute(arguments: Data) async throws -> String {
        let argsJSON = String(data: arguments, encoding: .utf8) ?? "{}"
        return try await bundle.call(name: spec.name, argsJSON: argsJSON)
    }
}
