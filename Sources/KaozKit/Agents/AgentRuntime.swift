import Foundation
import KaozJS
import KaozJSCore   // xsBridgeAddModuleRoot / xsBridgeClearModuleRoots (module roots)

public enum AgentError: Error, LocalizedError {
    case engineCreationFailed
    case evaluation(String)
    /// The agent's own `run(input)` threw or rejected.
    case script(String)
    /// The agent did not settle within its time budget.
    case timeout

    public var errorDescription: String? {
        switch self {
        case .engineCreationFailed: return "Impossible de créer le moteur JavaScript."
        case .evaluation(let m):    return "Erreur d'évaluation : \(m)"
        case .script(let m):        return m
        case .timeout:              return "L'agent n'a pas terminé dans le délai imparti."
        }
    }
}

/// Runs a standalone JavaScript agent: a module that exports
/// `async function run(input)` (or `default`) and drives the LLM, tools and
/// memory through `host.*`. One engine per run, torn down when the agent
/// finishes. The agent's returned value is reported via `host.__report`
/// (success) or `host.__fail` (throw/rejection); `run` returns it as a JSON
/// string (a string result comes back JSON-quoted).
public nonisolated final class AgentRuntime {

    private let makeProvider: @Sendable () -> (any LLMProvider)?
    private let resolveProvider: (@Sendable (String, [String: Any]) -> (any LLMProvider)?)?
    private let providerCatalog: [ProviderDescriptor]
    private let tools: ToolRegistry
    private let memory: MemoryStoring
    private let tokenBudget: Int?
    private let persona: String?
    private let log: @Sendable (String) -> Void

    public init(
        makeProvider: @escaping @Sendable () -> (any LLMProvider)?,
        resolveProvider: (@Sendable (String, [String: Any]) -> (any LLMProvider)?)? = nil,
        providerCatalog: [ProviderDescriptor] = [],
        tools: ToolRegistry,
        memory: MemoryStoring,
        tokenBudget: Int? = nil,
        persona: String? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.makeProvider = makeProvider
        self.resolveProvider = resolveProvider
        self.providerCatalog = providerCatalog
        self.tools = tools
        self.memory = memory
        self.tokenBudget = tokenBudget
        self.persona = persona
        self.log = log
    }

    /// - Parameter libraryRoot: folder whose `.js` files the agent may `import`
    ///   with explicit relative specifiers (`./util.js`); nil disables imports.
    /// - Parameter moduleBase: directory a relative `new Service(t, "./sub.mjs")`
    ///   specifier resolves against (typically the agent script's own folder).
    public func run(
        script: String,
        input: Any? = nil,
        timeout: TimeInterval = 10,
        libraryRoot: URL? = nil,
        moduleBase: URL? = nil
    ) async throws -> String {
        let staging = try AgentModuleStaging(agentSource: script, libraryRoot: libraryRoot)
        // Enable JS-initiated spawn: a script may `new Thread()` + `new Service()`
        // to run sub-agents, each a child engine with this same host wiring.
        TyKaozThreads.register { [makeProvider, resolveProvider, providerCatalog, tokenBudget, persona, tools, memory, log] in
            TyKaozHost(
                makeProvider: makeProvider, resolveProvider: resolveProvider,
                providerCatalog: providerCatalog, tools: tools, memory: memory,
                tokenBudget: tokenBudget, persona: persona, log: log)
        }
        let host = TyKaozHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: log)
        return try await withCheckedThrowingContinuation { continuation in
            let session = AgentSession(
                host: host, entry: staging.agentPath, staging: staging,
                moduleBase: moduleBase, continuation: continuation)
            session.start(input: input, timeout: timeout)
        }
    }

    /// Run an agent the Moddable way: no staging temp copy — the agent and its
    /// modules are imported directly from disk, resolved against `roots`.
    ///
    /// - Parameter entryModule: bare specifier for the agent, resolved against
    ///   the default (`""`) root — typically the script's filename without
    ///   extension (`"agent"` → `<root>/agent.{xsb,mjs,js}`).
    /// - Parameter roots: process-wide module roots. `""` prefix = a default
    ///   root for bare specifiers (searched in order); a named prefix maps
    ///   `<prefix>/x` to that dir. Resolution is confined to the roots (no
    ///   `../` escape). Registered for the run, cleared when it ends.
    public func runRooted(
        entryModule: String,
        roots: [(prefix: String, dir: String)],
        input: Any? = nil,
        timeout: TimeInterval = 10
    ) async throws -> String {
        TyKaozThreads.register { [makeProvider, resolveProvider, providerCatalog, tokenBudget, persona, tools, memory, log] in
            TyKaozHost(
                makeProvider: makeProvider, resolveProvider: resolveProvider,
                providerCatalog: providerCatalog, tools: tools, memory: memory,
                tokenBudget: tokenBudget, persona: persona, log: log)
        }
        let host = TyKaozHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: log)
        return try await withCheckedThrowingContinuation { continuation in
            let session = AgentSession(
                host: host, entry: entryModule, roots: roots, continuation: continuation)
            session.start(input: input, timeout: timeout)
        }
    }

    /// Rooted mode for an agent whose source is an in-memory string (not a file
    /// on disk) — e.g. an app that stores agents as records. The source is
    /// written to a private temp file (only the agent, no library copy) whose
    /// directory is the default entry root, searched alongside `roots` (the real,
    /// un-copied library / user folders). The agent imports bare specifiers
    /// straight from those folders; nothing is copied. Roots are process-wide for
    /// the run (shared by sub-agents) and cleared when it ends; the temp file is
    /// removed. The caller must hold security-scoped access to every root dir for
    /// the whole call (the engine reads them lazily on its own thread).
    public func runRootedSource(
        source: String,
        roots: [(prefix: String, dir: String)],
        input: Any? = nil,
        timeout: TimeInterval = 10
    ) async throws -> String {
        // libraryRoot: nil — stage the agent alone, no folder copy.
        let staging = try AgentModuleStaging(agentSource: source, libraryRoot: nil)
        TyKaozThreads.register { [makeProvider, resolveProvider, providerCatalog, tokenBudget, persona, tools, memory, log] in
            TyKaozHost(
                makeProvider: makeProvider, resolveProvider: resolveProvider,
                providerCatalog: providerCatalog, tools: tools, memory: memory,
                tokenBudget: tokenBudget, persona: persona, log: log)
        }
        let host = TyKaozHost(
            makeProvider: makeProvider, resolveProvider: resolveProvider,
            providerCatalog: providerCatalog, tools: tools, memory: memory,
            tokenBudget: tokenBudget, persona: persona, log: log)
        // The staged agent's dir is the first default root; `import "agent"`
        // resolves to it, real folders follow for the agent's own imports.
        var allRoots: [(prefix: String, dir: String)] = [("", staging.root.path)]
        allRoots.append(contentsOf: roots)
        return try await withCheckedThrowingContinuation { continuation in
            let session = AgentSession(
                host: host, entry: "agent", staging: staging, roots: allRoots,
                continuation: continuation)
            session.start(input: input, timeout: timeout)
        }
    }
}

/// Owns one engine + host for the lifetime of a single agent run. Retains
/// itself until the continuation is resumed, then releases the engine off the
/// XS thread (its deinit joins that thread, so it must not run on it).
private nonisolated final class AgentSession {

    private let host: TyKaozHost
    /// The specifier handed to `__runAgent`: a staged absolute path (staged
    /// mode) or a bare module name resolved against `roots` (rooted mode).
    private let entry: String
    /// Non-nil in staged mode — the temp dir to clean up after the run.
    private let staging: AgentModuleStaging?
    /// Non-nil in rooted mode — process-wide module roots to register on start
    /// and clear on completion. `""` prefix = default root for bare specifiers.
    private let roots: [(prefix: String, dir: String)]?
    private let moduleBase: URL?
    private var engine: XSEngine?
    private var continuation: CheckedContinuation<String, Error>?
    private var selfRef: AgentSession?
    private var timeoutItem: DispatchWorkItem?
    private let lock = NSLock()

    init(host: TyKaozHost, entry: String,
         staging: AgentModuleStaging? = nil,
         roots: [(prefix: String, dir: String)]? = nil,
         moduleBase: URL? = nil,
         continuation: CheckedContinuation<String, Error>) {
        self.host = host
        self.entry = entry
        self.staging = staging
        self.roots = roots
        self.moduleBase = moduleBase
        self.continuation = continuation
    }

    func start(input: Any?, timeout: TimeInterval) {
        selfRef = self

        let timeoutItem = DispatchWorkItem { [weak self] in
            self?.complete(.failure(AgentError.timeout))
        }
        self.timeoutItem = timeoutItem
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

        host.onReport = { [weak self] result in self?.complete(.success(result)) }
        host.onFail = { [weak self] err in self?.complete(.failure(AgentError.script(err))) }

        guard let engine = XSEngine.tyKaoz(host: host) else {
            complete(.failure(AgentError.engineCreationFailed))
            return
        }
        self.engine = engine
        engine.installThreads()   // `Thread` / `Service` globals for JS-initiated spawn
        // Rooted mode: register process-wide module roots so the agent (and its
        // sub-agents, which share the process-wide registry) resolve bare
        // specifiers against them, confined to the roots. Registered here on the
        // XS thread, before any import; cleared in `complete`.
        if let roots {
            engine.withMachine { _ in
                xsBridgeClearModuleRoots()
                for root in roots { xsBridgeAddModuleRoot(root.prefix, root.dir) }
            }
        }
        if let base = moduleBase {
            _ = try? engine.eval("globalThis.__moduleBase = \(AgentJSON.jsLiteral(base.path))")
        }

        do {
            // The agent runs in module goal (dynamic import in __runAgent), so it
            // can use static `import ... from`.
            let inputJSON = AgentJSON.string(input ?? NSNull())
            _ = try engine.eval(
                "__runAgent(\(AgentJSON.jsLiteral(entry)), "
                + "\(AgentJSON.jsLiteral(inputJSON)))")
        } catch let error as XSError {
            complete(.failure(AgentError.evaluation(error.message)))
        } catch {
            complete(.failure(error))
        }
    }

    /// Resume the continuation at most once, then tear down.
    private func complete(_ result: Result<String, Error>) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let engine = self.engine
        self.engine = nil
        lock.unlock()

        timeoutItem?.cancel()
        timeoutItem = nil
        continuation.resume(with: result)
        host.onReport = nil
        host.onFail = nil

        let staging = self.staging
        let clearRoots = self.roots != nil
        // Release the engine off the XS thread (its deinit joins that thread,
        // which would deadlock if we're on it now — __report fires there). Drain
        // the run loop so the reporting call settles before the machine is
        // deleted, then clear any process-wide roots this run registered, drop
        // the last reference, and clean up the staging dir.
        if let engine {
            DispatchQueue.global().async {
                engine.runUntilIdle(timeout: 2)
                if clearRoots { engine.withMachine { _ in xsBridgeClearModuleRoots() } }
                withExtendedLifetime(engine) {}
                staging?.cleanup()
            }
        } else {
            if clearRoots { xsBridgeClearModuleRoots() }
            staging?.cleanup()
        }
        selfRef = nil
    }
}
