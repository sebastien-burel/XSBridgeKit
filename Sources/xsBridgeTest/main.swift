// xsBridgeTest — phase runner / test harness.
// Runs each phase's criteria, prints "PHASE n: PASS|FAIL", and exits non-zero
// if any criterion fails (usable in CI / non-interactive runs — PLAN annex).

import XSBridge      // C module — GC/leak/print introspection (test-only)
import XSBridgeKit   // Swift API — XSEngine
import XSBridgeTestC // C side of the demo host (installs host.*)
import Darwin
import Foundation

// Test instrumentation over the flat C API — not part of the consumer surface
// of XSBridgeKit, so it lives here, built on withMachine + pendingCount.
extension XSEngine {
    /// Like runUntilIdle, but forces a full GC on the XS thread every turn —
    /// stresses the rooting of in-flight resolve/reject/onToken slots (Phase 5).
    func runUntilIdleForcingGC(timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount > 0 {
            withMachine { xsBridgeCollectGarbage($0) }
            if Date() > deadline { break }
            usleep(2_000)
        }
    }

    /// (remembered, forgotten) — equal when idle if no slot leaked.
    var rememberForgetCounts: (UInt32, UInt32) {
        withMachine {
            var remembered: UInt32 = 0
            var forgotten: UInt32 = 0
            xsBridgeDebugCounts($0, &remembered, &forgotten)
            return (remembered, forgotten)
        }
    }

    /// Values passed to JS `print()` since the last install (capture lives in
    /// xsBridgeTestC; written on the XS thread, so read there via withMachine).
    var outputs: [String] {
        withMachine { _ in
            let n = Int(xsBridgeTestOutputCount())
            return (0..<n).compactMap {
                xsBridgeTestOutputAt(Int32($0)).map { String(cString: $0) }
            }
        }
    }
}

var failures = 0

/// A fresh engine with the demo host functions installed (CLI-style: the C
/// target registers host.echo/stream/fail/add, which call back into Swift).
func makeEngine() -> XSEngine? {
    guard let engine = XSEngine() else { return nil }
    engine.withMachine { xsBridgeTestInstall($0) }
    return engine
}

// Register the harness thread factory once: JS `new Thread(...)` spawns a child
// engine through it (see PHASE 7).
DemoThreads.register()

func check(_ label: String, _ condition: Bool) {
    print("  [\(condition ? "ok" : "XX")] \(label)")
    if !condition { failures += 1 }
}

func phaseResult(_ n: Int, _ before: Int) {
    let ok = failures == before
    print("PHASE \(n): \(ok ? "PASS" : "FAIL")")
}

/// Current resident memory in bytes — used to eyeball leaks across the stress loop.
func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? info.resident_size : 0
}

// ---- Phase 1: machine lifecycle + synchronous eval ----
do {
    let before = failures
    print("PHASE 1 — machine lifecycle + sync eval")

    guard let engine = makeEngine() else {
        check("create machine", false)
        phaseResult(1, before)
        exit(1)
    }

    // eval returns a value
    if let r = try? engine.eval("6 * 7") {
        check("eval(\"6 * 7\") == 42", r == "42")
    } else {
        check("eval(\"6 * 7\") == 42", false)
    }

    // eval throwing is caught and returned as an error — process survives
    do {
        _ = try engine.eval("throw new Error('boom')")
        check("eval(throw) reported as error", false)
    } catch let e as XSError {
        check("eval(throw) reported as error (\(e.message))", e.message.range(of: "boom") != nil)
    } catch {
        check("eval(throw) reported as error", false)
    }

    // process is still alive and the same machine still works after the throw
    check("machine usable after exception", (try? engine.eval("1 + 1")) == "2")

    // N create/delete cycles — no crash, no leak.
    // Count overridable via XSB_MACHINE_ITERS (used by the Phase 5 stress test).
    let iters = ProcessInfo.processInfo.environment["XSB_MACHINE_ITERS"].flatMap { Int($0) } ?? 1000

    func cycle() -> Bool {
        guard let e = makeEngine() else { return false }
        return (try? e.eval("({a:1,b:2})")) != nil
        // e released here -> xsBridgeDeleteMachine
    }

    // Warm up so the one-time high-water marks are established before measuring:
    // the allocator's mapped regions (one machine ≈ 16 MB chunk + slot heap) AND
    // the pthread stack cache (each engine runs on its own 4 MB-stack thread, A3).
    // The leak test is then growth ACROSS the loop, which must stay bounded — a
    // true per-machine leak would scale with `iters` (hundreds of MB over 1000).
    for _ in 0..<50 { _ = cycle() }

    // Steady-state RSS. libmalloc keeps freed large allocations (a machine's
    // 16 MB chunk) in a per-zone cache for reuse, so a naive sample can show a
    // spurious one-time +16 MB that is cache, not a leak. Ask the allocator to
    // return cached free memory to the OS first, so RSS reflects true usage.
    func steadyRSS() -> UInt64 {
        malloc_zone_pressure_relief(nil, 0)
        return residentBytes()
    }

    let rssBefore = steadyRSS()
    var loopOK = true
    for _ in 0..<iters {
        if !cycle() { loopOK = false; break }
    }
    let rssAfter = steadyRSS()
    check("\(iters) machine create/eval/delete cycles", loopOK)
    let mb: Double = 1_048_576
    let growthMB: Double = (Double(rssAfter) - Double(rssBefore)) / mb
    print(String(format: "  RSS across loop: %.1f MB -> %.1f MB (delta %+.1f MB)",
                 Double(rssBefore) / mb, Double(rssAfter) / mb, growthMB))
    // Coarse machine-level guard: RSS must not grow unboundedly. The ceiling is
    // generous (< 30 MB) on purpose — each engine runs on its own thread (A3),
    // so cycling 1000 of them leaves the OS holding a small *bounded* cache of
    // freed 4 MB thread stacks (~16 MB observed, doesn't scale with `iters`,
    // not flushable via malloc APIs). A genuine leak (machines/threads/slots not
    // freed) would be GB-scale here. Exact slot-leak detection is the
    // remember/forget balance asserted in Phases 3-5.
    check("no unbounded machine leak (delta < 30 MB)", growthMB < 30)

    phaseResult(1, before)
}

// ---- Phase 2: synchronous host function (JS -> Swift) ----
do {
    let before = failures
    print("PHASE 2 — synchronous host function (JS -> Swift)")

    guard let engine = makeEngine() else {
        check("create machine", false)
        phaseResult(2, before)
        exit(1)
    }

    DemoHost.syncCallCount = 0
    let result = try? engine.eval("host.add(2, 3)")
    check("host.add(2, 3) == 5", result == "5")
    check("Swift host call executed (count == 1)", DemoHost.syncCallCount == 1)

    phaseResult(2, before)
}

// ---- Phase 3: asynchronous bridge (THE critical phase) ----
do {
    let before = failures
    print("PHASE 3 — async bridge (echo)")

    // Test A: load agents/echo.js — `const r = await host.echo("hi"); print(r)`.
    if let engine = makeEngine() {
        let path = "agents/echo.js"
        if let src = try? String(contentsOfFile: path, encoding: .utf8) {
            _ = try? engine.eval(src)
            check("echo kicked off one async call", engine.pendingCount == 1)
            engine.runUntilIdle()
            check("echo.js printed \"hi\"", engine.outputs == ["hi"])
            check("all async calls settled", engine.pendingCount == 0)
        } else {
            check("read \(path)", false)
        }
    } else {
        check("create machine", false)
    }

    // Test B: 100 sequential echoes — all correct, no leak.
    if let engine = makeEngine() {
        let n = 100
        let agent = """
        (async () => {
          for (let i = 0; i < \(n); i++) {
            const r = await host.echo("n" + i);
            print(r);
          }
        })();
        """
        _ = try? engine.eval(agent)
        engine.runUntilIdle(timeout: 30)

        let out = engine.outputs
        check("\(n) sequential echoes all printed", out.count == n)
        let allCorrect = out.enumerated().allSatisfy { $0.element == "n\($0.offset)" }
        check("\(n) echoes all correct and in order", allCorrect)
        check("id table empty at end", engine.pendingCount == 0)
        let (remembered, forgotten) = engine.rememberForgetCounts
        check("remember/forget balanced (\(remembered) == \(forgotten))", remembered == forgotten)
        check("rooted exactly 2 slots per call (\(remembered) == \(2 * n))", remembered == UInt32(2 * n))
    } else {
        check("create machine", false)
    }

    phaseResult(3, before)
}

// ---- Phase 4: streaming via reverse channel ----
do {
    let before = failures
    print("PHASE 4 — streaming (reverse channel)")

    if let engine = makeEngine() {
        let path = "agents/stream.js"
        if let src = try? String(contentsOfFile: path, encoding: .utf8) {
            _ = try? engine.eval(src)
            let start = Date()
            engine.runUntilIdle()
            let elapsed = Date().timeIntervalSince(start)

            let out = engine.outputs
            let expected = ["delta:Hello", "delta: ", "delta:from", "delta: ",
                            "delta:Swift", "full:Hello from Swift"]
            check("5 deltas then final, in order", out == expected)
            let deltas = out.filter { $0.hasPrefix("delta:") }
            check("received 5 deltas", deltas.count == 5)
            // Tokens are 50 ms apart: a single block would finish near-instantly.
            check("tokens arrived incrementally (elapsed \(String(format: "%.2f", elapsed))s ≥ 0.2s)",
                  elapsed >= 0.2)
            check("all settled", engine.pendingCount == 0)
            let (remembered, forgotten) = engine.rememberForgetCounts
            check("remember/forget balanced (\(remembered) == \(forgotten))", remembered == forgotten)
            check("rooted 3 slots (resolve+reject+onToken) (\(remembered) == 3)", remembered == 3)
        } else {
            check("read \(path)", false)
        }
    } else {
        check("create machine", false)
    }

    phaseResult(4, before)
}

// ---- Phase 5: concurrency & robustness ----
do {
    let before = failures
    print("PHASE 5 — concurrency & robustness")

    func loadAgent(_ name: String) -> String? {
        try? String(contentsOfFile: "agents/\(name)", encoding: .utf8)
    }

    func balanced(_ engine: XSEngine) -> Bool {
        let (r, f) = engine.rememberForgetCounts
        return r == f && engine.pendingCount == 0
    }

    // Concurrent: Promise.all of several in-flight echoes, no id crosstalk.
    if let engine = makeEngine(), let src = loadAgent("concurrent.js") {
        _ = try? engine.eval(src)
        engine.runUntilIdle()
        check("concurrent Promise.all preserves results", engine.outputs == ["all:a,b,c,d"])
        check("concurrent: roots balanced, table empty", balanced(engine))
    } else {
        check("concurrent.js", false)
    }

    // Reject path: host.fail() -> Swift reject -> JS catch, no escape to Swift.
    if let engine = makeEngine(), let src = loadAgent("error.js") {
        _ = try? engine.eval(src)
        engine.runUntilIdle()
        check("reject surfaces in JS catch", engine.outputs == ["caught:deliberate failure"])
        check("reject: roots balanced, table empty", balanced(engine))
    } else {
        check("error.js", false)
    }

    // Mixed sequential agent: echo then stream, distinct ids, no crosstalk.
    if let engine = makeEngine(), let src = loadAgent("sequential.js") {
        _ = try? engine.eval(src)
        engine.runUntilIdle()
        let expected = ["echo:first", "delta:Hello", "delta: ", "delta:from",
                        "delta: ", "delta:Swift", "stream:Hello from Swift"]
        check("mixed echo+stream agent in order", engine.outputs == expected)
        check("mixed: roots balanced, table empty", balanced(engine))
    } else {
        check("sequential.js", false)
    }

    // Stress: >= 5000 calls, batches in flight, forced GC between turns.
    if let engine = makeEngine() {
        let batches = 100, perBatch = 50  // 5000 calls
        let agent = """
        (async () => {
          let ok = 0, bad = 0;
          for (let b = 0; b < \(batches); b++) {
            const ps = [];
            for (let i = 0; i < \(perBatch); i++) {
              const v = "v" + b + "_" + i;
              ps.push(host.echo(v).then(r => { r === v ? ok++ : bad++; }));
            }
            await Promise.all(ps);
          }
          print("stress ok:" + ok + " bad:" + bad);
        })();
        """
        let rssBefore = residentBytes()
        _ = try? engine.eval(agent)
        engine.runUntilIdleForcingGC()
        let rssAfter = residentBytes()

        let total = batches * perBatch
        check("stress: \(total) calls all correct, none mixed up",
              engine.outputs == ["stress ok:\(total) bad:0"])
        check("stress: id table empty", engine.pendingCount == 0)
        let (remembered, forgotten) = engine.rememberForgetCounts
        check("stress: remember/forget balanced (\(remembered) == \(forgotten))",
              remembered == forgotten)
        check("stress: rooted 2 per call (\(remembered) == \(2 * total))",
              remembered == UInt32(2 * total))
        let growthMB = (Double(rssAfter) - Double(rssBefore)) / 1_048_576
        print(String(format: "  stress RSS: %.1f MB -> %.1f MB (delta %+.1f MB)",
                     Double(rssBefore) / 1_048_576, Double(rssAfter) / 1_048_576, growthMB))
        check("stress: memory stable (delta < 20 MB)", growthMB < 20)
    } else {
        check("create machine", false)
    }

    phaseResult(5, before)
}

// ---- Phase 6: ES module loader (custom fxFindModule / fxLoadModule) ----
do {
    let before = failures
    print("PHASE 6 — ES module loader")

    if let engine = makeEngine() {
        // Dynamic import resolves through the filesystem loader (cwd-relative,
        // explicit extension); the imported module itself uses a static
        // `import ... from './…'` (module goal, importer-relative), so a green
        // here proves both the loader wiring and module-goal parsing.
        _ = try? engine.eval("""
            globalThis.__m = 'pending';
            import('agents/modules/reexport.js')
              .then(function (m) { globalThis.__m = 'ok:' + m.doubled; })
              .catch(function (e) { globalThis.__m = 'err:' + String(e); });
            """)
        engine.runUntilIdle()
        let r = (try? engine.eval("globalThis.__m")) ?? "<none>"
        check("dynamic import + static re-export == 84 (got \(r))", r == "\"ok:84\"")

        // A missing module rejects cleanly — no crash, catchable in JS.
        _ = try? engine.eval("""
            globalThis.__n = 'pending';
            import('ghost').then(function () { globalThis.__n = 'resolved'; })
                           .catch(function () { globalThis.__n = 'rejected'; });
            """)
        engine.runUntilIdle()
        let r2 = (try? engine.eval("globalThis.__n")) ?? "<none>"
        check("missing module rejects (got \(r2))", r2 == "\"rejected\"")
    } else {
        check("create machine", false)
    }

    phaseResult(6, before)
}

// PHASE 7: JS-initiated thread spawn + GC teardown (the Thread primitive). A
// script creates child engines with `new Thread(...)`; unreferenced, they are
// collected and their host destructor tears the child engine down — everything
// initiated from JS, machine lifecycle owned by Swift's factory.
do {
    let before = failures
    print("PHASE 7: JS Thread spawn + teardown")
    DemoThreads.resetCounters()
    if let engine = makeEngine() {
        engine.withMachine { xsThreadInstall($0) }
        _ = try? engine.eval("(function () { new Thread('w1'); new Thread('w2'); })(); 0")
        check("2 child engines spawned (\(DemoThreads.createdCount))",
              DemoThreads.createdCount == 2)
        // The Thread objects are unreferenced; a full GC finalizes them, and
        // each host destructor tears its child engine down.
        engine.withMachine { xsBridgeCollectGarbage($0) }
        engine.withMachine { xsBridgeCollectGarbage($0) }
        check("both child engines torn down after GC (\(DemoThreads.destroyedCount))",
              DemoThreads.destroyedCount == 2)
    } else {
        check("create engine", false)
    }
    phaseResult(7, before)
}

// PHASE 8: JS-initiated Service round-trip. A supervisor script spawns a child
// engine (`new Thread`), binds a `Service` to a module, and `await`s methods on
// it — args and result cross as alien-marshalled values; the child imports the
// module and runs its default export. Everything is initiated from the script.
do {
    let before = failures
    print("PHASE 8: JS Thread + Service round-trip")
    // Source = a module (imported by the child via an absolute specifier).
    let moduleURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("xsb-service-\(getpid()).mjs")
    let moduleSrc = """
    export default {
        double({ n }) { return { doubled: n * 2 }; },
        greet({ who }) { return new Promise(function (r) { r({ hello: who }); }); }
    };
    """
    try? moduleSrc.write(to: moduleURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: moduleURL) }

    if let engine = makeEngine() {
        engine.withMachine { xsThreadInstall($0) }
        let script = """
        globalThis.__r = 'pending';
        (async function () {
            const t = new Thread('worker');
            const svc = new Service(t, '\(moduleURL.path)');
            const a = await svc.double({ n: 21 });   // sync handler
            const b = await svc.greet({ who: 'tykaoz' });  // Promise handler
            globalThis.__r = { a: a, b: b };
        })().catch(function (e) { globalThis.__r = { error: String((e && e.stack) || e) }; });
        """
        _ = try? engine.eval(script)
        engine.runUntilIdle(timeout: 5)
        let got = (try? engine.eval("globalThis.__r")) ?? "<none>"
        check("service round-trip via Thread+Service (got \(got))",
              got.contains("\"doubled\":42") && got.contains("\"hello\":\"tykaoz\""))
        // Invariant #4: the client rooted resolve/reject per call and forgot them
        // at settle — balanced, and no call left pending.
        engine.withMachine { m in
            var remembered: UInt32 = 0, forgotten: UInt32 = 0
            xsBridgeDebugCounts(m, &remembered, &forgotten)
            check("client roots balanced (\(remembered) == \(forgotten))", remembered == forgotten)
            check("client idle (pending == 0)", xsBridgePendingCount(m) == 0)
        }
    } else {
        check("create engine", false)
    }
    phaseResult(8, before)
}

exit(failures == 0 ? 0 : 1)
