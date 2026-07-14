// DemoHost — Swift side of the demo host (echo / stream / fail / add), the
// regression surface of the 6-phase suite. The C target xsBridgeTestC installs
// host.* functions that call these @_cdecl entry points; async results settle
// via xsBridgeComplete / xsBridgeEmitToken. A real consumer (TyKaoz) supplies
// its own C+Swift pair mapping host functions to tools and LLM providers.

import XSBridge
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
        xsBridgeComplete(bridge, id, 1, payload)
    }
}

@_cdecl("xsbDemoFail")
func xsbDemoFail(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32) {
    guard let bridge else { return }
    DemoHost.queue.asyncAfter(deadline: .now() + DemoHost.callLatency) {
        xsBridgeComplete(bridge, id, 0, DemoHost.jsonString("deliberate failure"))
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
            xsBridgeEmitToken(bridge, id, DemoHost.jsonString(token))
        }
        Thread.sleep(forTimeInterval: DemoHost.streamLatency)
        xsBridgeComplete(bridge, id, 1, DemoHost.jsonString(full))
    }
}
