// XSEngine — Swift wrapper over the C bridge, running each XS machine on its own
// dedicated thread + CFRunLoop (A3). XS is single-threaded (PLAN invariant 3):
// every machine access is marshalled onto that thread; async completions
// (xsb_complete / xsb_emit_token) wake the same run loop, so they settle there
// too. Callers (e.g. a UI thread) never touch the machine directly.

import XSBridge
import Foundation

public struct XSError: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// A dedicated thread running a CFRunLoop, onto which work is submitted and run
/// synchronously. The run loop also services the machine's CFRunLoopSource, so
/// async host completions are applied here without the caller doing anything.
private final class RunLoopThread {
    private let thread: Thread
    private let runLoop: CFRunLoop
    private let finished: DispatchSemaphore

    init() {
        var captured: CFRunLoop?
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let t = Thread {
            captured = CFRunLoopGetCurrent()
            // Keep the loop alive even before the machine adds its source: a
            // timer that never fires. Without a source/timer, CFRunLoopRun exits.
            let timer = CFRunLoopTimerCreateWithHandler(
                nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            started.signal()
            CFRunLoopRun()
            finished.signal()   // CFRunLoopRun returned -> thread is exiting
        }
        t.stackSize = 4 << 20
        t.start()
        started.wait()
        thread = t
        runLoop = captured!
        self.finished = finished
    }

    /// Run `work` on the dedicated thread and block until it returns.
    func sync<T>(_ work: @escaping () -> T) -> T {
        if CFEqual(CFRunLoopGetCurrent(), runLoop) { return work() }
        var result: T!
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            result = work()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
        return result
    }

    /// Stop the run loop and block until the thread has fully exited (joins it,
    /// so its stack is reclaimed before we return — keeps machine churn bounded).
    func stop() {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(runLoop)
        finished.wait()
    }
}

public final class XSEngine {
    private let loop = RunLoopThread()
    private let machine: UnsafeMutableRawPointer
    let host: HostBridge

    public init?(host: HostBridge) {
        self.host = host
        // The machine (and its CFRunLoopSource) must be created ON the dedicated
        // thread, so the source is attached to that thread's run loop.
        guard let m = (loop.sync { xsb_create_machine() }) else { return nil }
        machine = m
        loop.sync {
            xsb_set_context(m, Unmanaged.passUnretained(self).toOpaque())
        }
        if !host.prelude.isEmpty {
            _ = try? eval(host.prelude)
        }
    }

    deinit {
        let m = machine
        loop.sync { xsb_delete_machine(m) }
        loop.stop()
    }

    /// Evaluate JS source synchronously on the XS thread.
    @discardableResult
    public func eval(_ src: String) throws -> String {
        let result: Result<String, XSError> = loop.sync {
            var outJSON: UnsafeMutablePointer<CChar>?
            var outErr: UnsafeMutablePointer<CChar>?
            let ok = xsb_eval(self.machine, src, &outJSON, &outErr)
            defer {
                if let p = outJSON { xsb_free(p) }
                if let p = outErr { xsb_free(p) }
            }
            if ok != 0 {
                return .success(String(cString: outJSON!))
            }
            return .failure(XSError(message: outErr.map { String(cString: $0) } ?? "unknown error"))
        }
        return try result.get()
    }

    /// Block until all in-flight async calls have settled (or timeout). The
    /// dedicated thread's run loop applies completions on its own; we just wait.
    public func runUntilIdle(timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount > 0 {
            if Date() > deadline { break }
            usleep(2_000)
        }
    }

    /// Like runUntilIdle, but forces a full GC on the XS thread every turn —
    /// stresses the rooting of in-flight resolve/reject/onToken slots (Phase 5).
    public func runUntilIdleForcingGC(timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingCount > 0 {
            loop.sync { xsb_collect_garbage(self.machine) }
            if Date() > deadline { break }
            usleep(2_000)
        }
    }

    public var pendingCount: Int { loop.sync { Int(xsb_pending_count(self.machine)) } }

    /// (remembered, forgotten) — equal when idle if no slot leaked.
    public var rememberForgetCounts: (UInt32, UInt32) {
        loop.sync {
            var remembered: UInt32 = 0
            var forgotten: UInt32 = 0
            xsb_debug_counts(self.machine, &remembered, &forgotten)
            return (remembered, forgotten)
        }
    }

    /// Values passed to JS `print()`, in order.
    public var outputs: [String] {
        loop.sync {
            let n = Int(xsb_output_count(self.machine))
            return (0..<n).compactMap {
                xsb_output_at(self.machine, Int32($0)).map { String(cString: $0) }
            }
        }
    }
}
