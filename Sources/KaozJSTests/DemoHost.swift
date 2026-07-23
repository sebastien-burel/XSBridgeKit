// DemoHost — Swift side of the demo host (echo / stream / fail / add), the
// regression surface of the 6-phase suite. The C target KaozJSTestC installs
// host.* functions that call these @_cdecl entry points; async results settle
// via xsServiceResolve / xsServiceEmit. A real consumer (TyKaoz) supplies
// its own C+Swift pair mapping host functions to tools and LLM providers.

import KaozJSCore
import KaozJS
import KaozJSTestC
import Foundation

enum DemoHost {
    /// Counts synchronous host calls — lets the harness observe Swift ran (Phase 2).
    static var syncCallCount = 0

    // Small per-call latency (echo/fail) keeps the stress test fast; a larger
    // inter-token latency makes streaming observably gradual.
    static let callLatency: TimeInterval = 0.005
    static let streamLatency: TimeInterval = 0.05
    static let queue = DispatchQueue(label: "net.burel.xsbridge.demohost", attributes: .concurrent)

    /// JSON-encode a value (e.g. a String -> `"..."`, a number -> `5`).
    static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: value, options: [.fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return str
    }
}

@_cdecl("xsbDemoAdd")
func xsbDemoAdd(_ a: Double, _ b: Double) -> Double {
    DemoHost.syncCallCount += 1
    return a + b
}

@_cdecl("xsbDemoEcho")
func xsbDemoEcho(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge else { return }
    let payload = json.map { String(cString: $0) } ?? "null"
    DemoHost.queue.asyncAfter(deadline: .now() + DemoHost.callLatency) {
        xsServiceResolve(bridge, id, payload)
    }
}

@_cdecl("xsbDemoFail")
func xsbDemoFail(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32) {
    guard let bridge else { return }
    DemoHost.queue.asyncAfter(deadline: .now() + DemoHost.callLatency) {
        xsServiceReject(bridge, id, DemoHost.jsonString("deliberate failure"))
    }
}

@_cdecl("xsbDemoStream")
func xsbDemoStream(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32) {
    guard let bridge else { return }
    DemoHost.queue.async {
        let tokens = ["Hello", " ", "from", " ", "Swift"]
        var full = ""
        for token in tokens {
            Thread.sleep(forTimeInterval: DemoHost.streamLatency)
            full += token
            xsServiceEmit(bridge, id, DemoHost.jsonString(token))
        }
        Thread.sleep(forTimeInterval: DemoHost.streamLatency)
        xsServiceResolve(bridge, id, DemoHost.jsonString(full))
    }
}

/// Thread factory for the harness: JS `new Thread(name)` in any engine spawns a
/// child XSEngine here, installed with the demo host + the Thread/Service
/// globals so it can itself serve and spawn. Children are retained by their
/// machine pointer and released — torn down — when the parent's Thread object is
/// garbage-collected (its host destructor calls `destroy`).
enum DemoThreads {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var children: [UnsafeMutableRawPointer: XSEngine] = [:]
    nonisolated(unsafe) private static var created = 0
    nonisolated(unsafe) private static var destroyed = 0

    static let create: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer? = { _ in
        guard let child = XSEngine() else { return nil }
        let machine = child.withMachine { $0 }
        child.withMachine { xsThreadInstall($0) }
        child.withMachine { xsBridgeTestInstall($0) }
        lock.lock()
        children[machine] = child
        created += 1
        lock.unlock()
        return machine
    }

    static let destroy: @convention(c) (UnsafeMutableRawPointer?) -> Void = { machine in
        guard let machine else { return }
        lock.lock()
        let engine = children.removeValue(forKey: machine)
        destroyed += 1
        lock.unlock()
        _ = engine   // deinit (child thread teardown) runs here, after the unlock
    }

    static func register() { xsBridgeRegisterThreadFactory(create, destroy) }
    static func resetCounters() { lock.lock(); created = 0; destroyed = 0; lock.unlock() }
    static var createdCount: Int { lock.lock(); defer { lock.unlock() }; return created }
    static var destroyedCount: Int { lock.lock(); defer { lock.unlock() }; return destroyed }
}
