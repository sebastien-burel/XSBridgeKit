// DemoHost — the demo HostBridge used by the test harness. It keeps the exact
// echo / stream / fail / add behaviour the 6-phase suite verifies, but now as a
// HostBridge implementation (regression coverage for the generalized dispatch).
// A real consumer (TyKaoz) would supply its own HostBridge mapping keys to tools
// and LLM providers, with its own prelude.

import XSBridgeKit
import Foundation

final class DemoHost: HostBridge {
    /// Counts synchronous host calls — lets the harness observe Swift ran (Phase 2).
    private(set) var syncCallCount = 0

    // Small per-call latency (echo/fail) keeps the stress test fast; a larger
    // inter-token latency makes streaming observably gradual.
    private let callLatency: TimeInterval = 0.005
    private let streamLatency: TimeInterval = 0.05
    private let queue = DispatchQueue(label: "net.burel.xsbridge.demohost", attributes: .concurrent)

    /// Defines the host.* wrappers around the generic primitives.
    var prelude: String {
        """
        host.echo = function(x) { return new Promise(function(res, rej) { __nativeCall('echo', [x], res, rej); }); };
        host.stream = function(p, onTok) { return new Promise(function(res, rej) { __nativeCall('stream', [p], res, rej, onTok); }); };
        host.fail = function() { return new Promise(function(res, rej) { __nativeCall('fail', [], res, rej); }); };
        host.add = function(a, b) { return __nativeCallSync('add', [a, b]); };
        """
    }

    func handle(key: String, paramsJSON: String, responder: HostResponder) {
        switch key {
        case "stream":
            // Emit tokens one at a time, spaced out, then resolve with full text.
            queue.async {
                let tokens = ["Hello", " ", "from", " ", "Swift"]
                var full = ""
                for token in tokens {
                    Thread.sleep(forTimeInterval: self.streamLatency)
                    full += token
                    responder.emit(DemoHost.jsonString(token))
                }
                Thread.sleep(forTimeInterval: self.streamLatency)
                responder.resolve(DemoHost.jsonString(full))
            }
        case "fail":
            queue.asyncAfter(deadline: .now() + callLatency) {
                responder.reject(DemoHost.jsonString("deliberate failure"))
            }
        default: // "echo"
            queue.asyncAfter(deadline: .now() + callLatency) {
                let (ok, result) = DemoHost.compute(key: key, paramsJSON: paramsJSON)
                ok ? responder.resolve(result) : responder.reject(result)
            }
        }
    }

    func handleSync(key: String, paramsJSON: String) -> String {
        switch key {
        case "add":
            syncCallCount += 1
            guard let data = paramsJSON.data(using: .utf8),
                  let params = try? JSONSerialization.jsonObject(
                      with: data, options: [.fragmentsAllowed]) as? [Any],
                  params.count == 2 else {
                return "null"
            }
            let a = (params[0] as? NSNumber)?.doubleValue ?? 0
            let b = (params[1] as? NSNumber)?.doubleValue ?? 0
            return DemoHost.jsonString(a + b)
        default:
            return "null"
        }
    }

    /// JSON-encode an arbitrary value (e.g. a String -> `"..."`, a number -> `5`).
    private static func jsonString(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(
                  withJSONObject: value, options: [.fragmentsAllowed]),
              let str = String(data: data, encoding: .utf8) else {
            return "null"
        }
        return str
    }

    /// For "echo", the result is params[0].
    private static func compute(key: String, paramsJSON: String) -> (Bool, String) {
        switch key {
        case "echo":
            guard let data = paramsJSON.data(using: .utf8),
                  let params = try? JSONSerialization.jsonObject(
                      with: data, options: [.fragmentsAllowed]) as? [Any],
                  let first = params.first,
                  let out = try? JSONSerialization.data(
                      withJSONObject: first, options: [.fragmentsAllowed]),
                  let str = String(data: out, encoding: .utf8) else {
                return (false, "\"echo: bad params\"")
            }
            return (true, str)
        default:
            return (false, "\"unknown host key: \(key)\"")
        }
    }
}
