/*
 * bridge.h — flat C API exposed to Swift.
 *
 * Invariant (PLAN §40.2): nothing XS-specific crosses this header to Swift.
 * Swift only ever sees plain C types — an opaque machine handle (void*),
 * opaque ids (uint32_t), C strings (UTF-8 JSON). No xsSlot, no xsMachine,
 * no XS macros (those live in bridgeXS.h, for consumer C targets only).
 */
#ifndef XSB_BRIDGE_H
#define XSB_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

/* ---- Machine lifecycle ---- */

/* VM sizing handed to xsCreateMachine — a flat mirror of the fields of
 * xsCreation (xs.h) that the bridge sets; the defaults live in Swift
 * (XSCreation, XSEngine.swift). */
typedef struct {
  int32_t initialChunkSize;
  int32_t incrementalChunkSize;
  int32_t initialHeapCount;
  int32_t incrementalHeapCount;
  int32_t stackCount;
  int32_t initialKeyCount;
  int32_t incrementalKeyCount;
  int32_t nameModulo;
  int32_t symbolModulo;
  int32_t parserBufferSize;
  int32_t parserTableModulo;
} XSBridgeCreation;

/* Create a full XS machine (engine with parser) sized by `creation`, plus its
 * async bridge and a CFRunLoopSource on the *current* run loop. Returns an
 * opaque handle or NULL. */
void* xsBridgeCreateMachine(const XSBridgeCreation* creation);

/* Destroy a machine and its bridge. Caller must ensure no async work is still
 * in flight (no pending ids) before deleting. */
void xsBridgeDeleteMachine(void* machine);

/* Set the opaque Swift context pointer recovered by xsBridgeGetContext. */
void xsBridgeSetContext(void* machine, void* context);

/* Recover the opaque Swift context from the bridge pointer that C host
 * functions obtain via xsGetContext(the) and hand to Swift. */
void* xsBridgeGetContext(void* bridge);

/* ---- Synchronous eval ---- */

/* Evaluate `src`. On success returns 1, *out_json = JSON result (or "undefined").
 * On JS error returns 0, *out_err = the message. Free returned strings with
 * xsBridgeFree. A JS exception is captured here and never crosses into Swift. */
int xsBridgeEval(void* machine, const char* src, char** out_json, char** out_err);

/* Free a string returned by this API. */
void xsBridgeFree(char* s);

/* ---- ES module runner ---- */

/* Import the ES module file at `path` (absolute, or relative to cwd; between
 * modules `./`/`../` resolve against the importer; extensions are explicit —
 * `.js`/`.mjs`/`.xsb`). If the module has a callable `default` export it is
 * invoked on every run (the body evaluates only once — module cache — the
 * default is the repeatable entry; the run settles with its result). When
 * `paramsJSON` is non-NULL the default receives JSON.parse(paramsJSON) as its
 * argument (a parse error rejects the run). Starts the import and drains
 * promise jobs; a module awaiting async host work settles later on the run
 * loop. XS-thread only. */
void xsBridgeRunModule(void* machine, const char* path, const char* paramsJSON);

/* Outcome of the last xsBridgeRunModule: 0 pending, 1 fulfilled, 2 rejected.
 * When rejected, *out_err = the message (free with xsBridgeFree). XS-thread only. */
int xsBridgeModuleStatus(void* machine, char** out_err);

/* ---- Async settlement (from Swift background threads) ---- */

/* Settle an in-flight native call by id: resolve(JSON.parse(json)) or
 * reject(JSON.parse(json)). The result is queued and the machine's run loop is
 * woken to settle on its own thread. Thread-safe. */
void xsServiceResolve(void* bridge, uint32_t id, const char* json);
void xsServiceReject(void* bridge, uint32_t id, const char* json);

/* Stream one token (the reverse channel): invokes the call's JS
 * onToken(JSON.parse(json)) and keeps the call open until a later
 * xsServiceResolve / xsServiceReject settles it. Thread-safe. */
void xsServiceEmit(void* bridge, uint32_t id, const char* json);

/* ---- JS-initiated threads (Thread / Service globals) ---- */

/* A consumer-provided factory for child engines spawned by JS `new Thread(name)`.
 * `create` must return a fully-installed child machine (its own machine+thread,
 * as from xsBridgeCreateMachine, with the consumer's host functions AND
 * xsThreadInstall so it can itself serve / spawn); `destroy` tears it down. The
 * factory is consumer-supplied because the socle installs no host capabilities.
 * `create` runs on the parent's XS thread (inside `new Thread`); it must create
 * and return synchronously. Registered once, process-wide, like the host table. */
typedef void* (*XSThreadCreate)(const char* name);
typedef void  (*XSThreadDestroy)(void* childMachine);
void xsBridgeRegisterThreadFactory(XSThreadCreate create, XSThreadDestroy destroy);

/* Install the `Thread` (and `Service`) globals on `machine`, so its JS can spawn
 * child engines and call them as services — everything initiated from the
 * script. Requires a thread factory registered. Run on the XS thread. */
void xsThreadInstall(void* machine);

/* ---- Introspection ---- */

/* Number of in-flight async calls (ids awaiting settlement). XS-thread only. */
int xsBridgePendingCount(void* machine);

/* Force a full GC on the XS thread (stress test: verifies roots survive). */
void xsBridgeCollectGarbage(void* machine);

/* Leak accounting: total xsRemember vs xsForget calls (must match when idle). */
void xsBridgeDebugCounts(void* machine, uint32_t* remembered, uint32_t* forgotten);

/* ---- Snapshot (persist / restore the JS heap) ---- */

/* Serialize the machine into a malloc'd buffer (*out, *outLen; free with
 * xsBridgeFree). Returns 0 on success, non-zero on error. Call at idle
 * (pending count 0) — in-flight async calls settle in Swift, off the heap.
 * Requires a host table registered via xsBridgeRegisterHostTable. XS-thread only. */
int xsBridgeWriteSnapshot(void* machine, char** out, size_t* outLen);

/* Restore a machine from snapshot bytes (creates it, reattaches the platform).
 * Rejects if the XS version/architecture differ or the registered host table is
 * not a prefix-compatible superset of the snapshot's. Returns an opaque handle
 * or NULL. Must run on the target run-loop thread. */
void* xsBridgeReadSnapshot(const char* bytes, size_t len);

/* The XS-typed helpers for consumer C host-function targets (xsServicePromise)
 * live in bridgeXS.h, which is NOT part of the clang module — include it
 * textually after xs.h in C translation units only. */

#endif /* XSB_BRIDGE_H */
