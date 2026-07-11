// HostBridge — the generic host-capability surface a consumer implements.
//
// The C bridge only provides the primitives __nativeCall / __nativeCallSync and
// routes every call to the engine's HostBridge by key. A consumer (the demo
// here; TyKaoz later) decides what keys mean and supplies a JS `prelude` that
// defines the ergonomic host.* wrappers around those primitives.

import XSBridge
import Foundation

/// Settles or streams an in-flight async host call. Thread-safe: a host may call
/// these from any queue; they wake the engine's run loop to apply on its thread.
public final class HostResponder {
    private let bridge: UnsafeMutableRawPointer
    private let id: UInt32

    init(bridge: UnsafeMutableRawPointer, id: UInt32) {
        self.bridge = bridge
        self.id = id
    }

    /// Stream one token (reverse channel); the call stays open.
    public func emit(_ json: String) { json.withCString { xsb_emit_token(bridge, id, $0) } }
    /// Settle the call as fulfilled with a JSON value.
    public func resolve(_ json: String) { json.withCString { xsb_complete(bridge, id, 1, $0) } }
    /// Settle the call as rejected with a JSON value.
    public func reject(_ json: String) { json.withCString { xsb_complete(bridge, id, 0, $0) } }
}

public protocol HostBridge: AnyObject {
    /// JS run once at engine creation to define the host.* convenience functions.
    var prelude: String { get }
    /// Async host call: use `responder` to stream and settle (possibly later).
    func handle(key: String, paramsJSON: String, responder: HostResponder)
    /// Synchronous host call returning a JSON result immediately.
    func handleSync(key: String, paramsJSON: String) -> String

    /// Resolve an ES module `specifier` (relative to `importer`, nil at the top
    /// level) to a canonical module id, or nil if it can't be resolved. Called
    /// synchronously on the engine thread during `import`. Default: no modules.
    func findModule(specifier: String, importer: String?) -> String?
    /// Return the source for a module `id` produced by `findModule`, or nil if
    /// absent. Called synchronously during `import`. Default: no modules.
    func loadModule(id: String) -> String?
}

public extension HostBridge {
    var prelude: String { "" }
    func handleSync(key: String, paramsJSON: String) -> String { "null" }
    func findModule(specifier: String, importer: String?) -> String? { nil }
    func loadModule(id: String) -> String? { nil }
}

// MARK: - C-callable dispatch entry points (resolved at executable link)

/// Recover the engine that owns `bridge`, via the opaque context pointer.
private func engine(for bridge: UnsafeMutableRawPointer) -> XSEngine? {
    guard let ctx = xsb_context_of(bridge) else { return nil }
    return Unmanaged<XSEngine>.fromOpaque(ctx).takeUnretainedValue()
}

@_cdecl("xsb_dispatch")
func xsb_dispatch(_ bridge: UnsafeMutableRawPointer?,
                  _ id: UInt32,
                  _ key: UnsafePointer<CChar>?,
                  _ json: UnsafePointer<CChar>?) {
    guard let bridge = bridge, let engine = engine(for: bridge) else { return }
    let key = key.map { String(cString: $0) } ?? ""
    let json = json.map { String(cString: $0) } ?? "[]"
    engine.host.handle(key: key, paramsJSON: json,
                       responder: HostResponder(bridge: bridge, id: id))
}

@_cdecl("xsb_dispatch_sync")
func xsb_dispatch_sync(_ bridge: UnsafeMutableRawPointer?,
                       _ key: UnsafePointer<CChar>?,
                       _ json: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let bridge = bridge, let engine = engine(for: bridge) else { return nil }
    let key = key.map { String(cString: $0) } ?? ""
    let json = json.map { String(cString: $0) } ?? "[]"
    // strdup so the C side owns the buffer and frees it after JSON.parse.
    return strdup(engine.host.handleSync(key: key, paramsJSON: json))
}

@_cdecl("xsb_dispatch_find_module")
func xsb_dispatch_find_module(_ bridge: UnsafeMutableRawPointer?,
                              _ specifier: UnsafePointer<CChar>?,
                              _ importer: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let bridge = bridge, let engine = engine(for: bridge),
          let specifier = specifier else { return nil }
    let spec = String(cString: specifier)
    let imp = importer.map { String(cString: $0) }
    guard let resolved = engine.host.findModule(specifier: spec, importer: imp) else { return nil }
    return strdup(resolved)   // C frees it
}

@_cdecl("xsb_dispatch_load_module")
func xsb_dispatch_load_module(_ bridge: UnsafeMutableRawPointer?,
                              _ id: UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? {
    guard let bridge = bridge, let engine = engine(for: bridge), let id = id else { return nil }
    guard let source = engine.host.loadModule(id: String(cString: id)) else { return nil }
    return strdup(source)   // C frees it
}
