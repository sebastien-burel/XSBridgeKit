import Foundation
import KaozJSCore
import KaozJS

/// Factory for child TyKaoz engines spawned by a script's `new Thread(...)`.
///
/// Everything about the sub-agent topology (who spawns, how many, how they are
/// named and wired) lives in the JavaScript: a supervisor script calls
/// `new Thread()` + `new Service(thread, moduleSpecifier)` and `await`s methods
/// on the module's default export. The only native part is creating the child
/// engine — done here, giving each child the full TyKaoz host surface
/// (`host.tool`, `host.llm`, memory) plus the `Thread`/`Service` globals, so a
/// sub-agent module can use `host.*` and itself spawn.
///
/// Children are retained until the parent's `Thread` object is garbage-collected
/// (its host destructor calls `destroy`), at which point the child engine is
/// torn down — lifecycle follows JS reachability.
public enum TyKaozThreads {
    /// Builds a fresh host for each spawned child (own tools/llm/memory wiring).
    /// Called on the parent's XS thread; `TyKaozHost.init` only stores its
    /// dependencies, so it is safe there.
    public typealias HostFactory = () -> TyKaozHost

    private static let lock = NSLock()
    nonisolated(unsafe) private static var makeHost: HostFactory?
    nonisolated(unsafe) private static var children: [UnsafeMutableRawPointer: (XSEngine, TyKaozHost)] = [:]

    /// Register the child-engine factory process-wide, enabling `new Thread` /
    /// `new Service` in engines that called `installThreads()`. Idempotent
    /// (last registration wins); call once during setup.
    public static func register(_ makeHost: @escaping HostFactory) {
        lock.lock()
        Self.makeHost = makeHost
        lock.unlock()
        xsBridgeRegisterThreadFactory(create, destroy)
    }

    private static let create: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _ in
        lock.lock()
        let make = makeHost
        lock.unlock()
        guard let make else { return nil }
        let host = make()
        guard let child = XSEngine.tyKaoz(host: host) else { return nil }
        child.installThreads()
        let machine = child.withMachine { $0 }
        lock.lock()
        children[machine] = (child, host)
        lock.unlock()
        return machine
    }

    private static let destroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { machine in
        guard let machine else { return }
        lock.lock()
        let held = children.removeValue(forKey: machine)
        lock.unlock()
        _ = held   // engine deinit (child thread teardown) + host release, after the unlock
    }
}
