// XSEngine — Swift wrapper over the C bridge, running each XS machine on its own
// dedicated thread + CFRunLoop (A3). XS is single-threaded (PLAN invariant 3):
// every machine access is marshalled onto that thread; async completions
// (xsServiceResolve / xsServiceEmit) wake the same run loop, so they settle there
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

/// VM sizing handed to xsCreateMachine. The defaults are the values validated
/// by the regression suite (derived from the xst mac target); override a field
/// to size a machine differently.
public struct XSCreation {
  public var initialChunkSize: Int32 = 16 * 1024 * 1024
  public var incrementalChunkSize: Int32 = 16 * 1024 * 1024
  public var initialHeapCount: Int32 = 1 * 1024 * 1024
  public var incrementalHeapCount: Int32 = 1 * 1024 * 1024
  public var stackCount: Int32 = 256 * 1024
  public var initialKeyCount: Int32 = 1024
  public var incrementalKeyCount: Int32 = 1024
  public var nameModulo: Int32 = 1993
  public var symbolModulo: Int32 = 127
  public var parserBufferSize: Int32 = 64 * 1024
  public var parserTableModulo: Int32 = 1993

  public init() {}
}

public final class XSEngine {
  private let loop = RunLoopThread()
  private let machine: UnsafeMutableRawPointer

  public init?(creation: XSCreation = XSCreation()) {
    // The machine (and its CFRunLoopSource) must be created ON the dedicated
    // thread, so the source is attached to that thread's run loop.
    let made: UnsafeMutableRawPointer? = loop.sync {
      var c = XSBridgeCreation(
        initialChunkSize: creation.initialChunkSize,
        incrementalChunkSize: creation.incrementalChunkSize,
        initialHeapCount: creation.initialHeapCount,
        incrementalHeapCount: creation.incrementalHeapCount,
        stackCount: creation.stackCount,
        initialKeyCount: creation.initialKeyCount,
        incrementalKeyCount: creation.incrementalKeyCount,
        nameModulo: creation.nameModulo,
        symbolModulo: creation.symbolModulo,
        parserBufferSize: creation.parserBufferSize,
        parserTableModulo: creation.parserTableModulo)
      return xsBridgeCreateMachine(&c)
    }
    guard let the = made else { return nil }
    self.machine = the
    loop.sync {
      xsBridgeSetContext(the, Unmanaged.passUnretained(self).toOpaque())
    }
  }

  /// Restore an engine from snapshot bytes produced by `writeSnapshot()`. The
  /// host table must already be registered (the consumer's C install/register
  /// path) and be prefix-compatible with the snapshot's, else this returns nil.
  public init?(snapshot: Data) {
    let made: UnsafeMutableRawPointer? = loop.sync {
      snapshot.withUnsafeBytes { raw in
        xsBridgeReadSnapshot(raw.bindMemory(to: CChar.self).baseAddress, raw.count)
      }
    }
    guard let the = made else { return nil }
    self.machine = the
    loop.sync {
      xsBridgeSetContext(the, Unmanaged.passUnretained(self).toOpaque())
    }
  }

  deinit {
    let the = machine
    loop.sync { xsBridgeDeleteMachine(the) }
    loop.stop()
  }

  /// Serialize the whole JS heap to bytes (restore with `init(snapshot:)`).
  /// Throws if async calls are still in flight (`pendingCount != 0`) — their
  /// settlement lives in Swift, off the heap, so a mid-flight snapshot would
  /// capture Promises that never resolve.
  public func writeSnapshot() throws -> Data {
    let result: Result<Data, XSError> = loop.sync {
      if Int(xsBridgePendingCount(self.machine)) != 0 {
        return .failure(XSError(message: "snapshot requires idle (pending calls in flight)"))
      }
      var out: UnsafeMutablePointer<CChar>?
      var len = 0
      let err = xsBridgeWriteSnapshot(self.machine, &out, &len)
      defer { if let out { xsBridgeFree(out) } }
      guard err == 0, let out else {
        return .failure(XSError(message: "snapshot write failed (\(err))"))
      }
      return .success(Data(bytes: out, count: len))
    }
    return try result.get()
  }

  /// Evaluate JS source synchronously on the XS thread.
  @discardableResult
  public func eval(_ src: String) throws -> String {
    let result: Result<String, XSError> = loop.sync {
      var outJSON: UnsafeMutablePointer<CChar>?
      var outErr: UnsafeMutablePointer<CChar>?
      let ok = xsBridgeEval(self.machine, src, &outJSON, &outErr)
      defer {
        if let p = outJSON { xsBridgeFree(p) }
        if let p = outErr { xsBridgeFree(p) }
      }
      if ok != 0 {
        return .success(String(cString: outJSON!))
      }
      return .failure(XSError(message: outErr.map { String(cString: $0) } ?? "unknown error"))
    }
    return try result.get()
  }

  /// Import the ES module file at `path` (absolute, or relative to the cwd;
  /// `./`/`../` between modules resolve against the importer, extensions are
  /// explicit). If the module has a callable `default` export, it is invoked
  /// on every run — the body evaluates only once (module cache), the default
  /// is the repeatable entry — and receives `JSON.parse(params)` when params
  /// are given. Waits until settled (top-level await and the default's result
  /// included) and throws XSError if the run rejects.
  public func runModule(_ path: String, params: String? = nil, timeout: TimeInterval = 5) throws {
    loop.sync {
      if let params {
        params.withCString { xsBridgeRunModule(self.machine, path, $0) }
      } else {
        xsBridgeRunModule(self.machine, path, nil)
      }
    }
    runUntilIdle(timeout: timeout)
    let error: String? = loop.sync {
      var err: UnsafeMutablePointer<CChar>?
      let status = xsBridgeModuleStatus(self.machine, &err)
      defer { if let p = err { xsBridgeFree(p) } }
      switch status {
        case 2: return err.map { String(cString: $0) } ?? "module rejected"
        case 0: return "module still pending after \(timeout)s"
        default: return nil
      }
    }
    if let error { throw XSError(message: error) }
  }

  /// Run `body` on the XS thread with the opaque machine handle — the escape
  /// hatch for consumer C extensions (e.g. installing extra host functions).
  /// Do not retain the pointer; it is only valid on the XS thread.
  public func withMachine<T>(_ body: @escaping (UnsafeMutableRawPointer) -> T) -> T {
    loop.sync { body(self.machine) }
  }

  // MARK: - Multi-machine services (Part D)

  /// Install the service-server plumbing (`__serviceReply` + `__runService`) on
  /// this engine. The consumer then sets a global `__serviceHandler(method,
  /// args)` (synchronous or Promise-returning) that answers incoming calls.
  public func installServiceServer() {
    withMachine { xsServiceInstallServer($0) }
  }

  /// Link this engine so its host functions (via `xsServiceInvoke`) call
  /// services on `server`. Values cross as alien-marshalled data — the two
  /// engines need no shared preparation.
  public func linkService(to server: XSEngine) {
    server.withMachine { s in self.withMachine { c in xsServiceLink(c, s) } }
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

  public var pendingCount: Int { loop.sync { Int(xsBridgePendingCount(self.machine)) } }
}
