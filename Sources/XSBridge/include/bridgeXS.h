/*
 * bridgeXS.h — bridge helpers for consumer C host-function targets.
 *
 * NOT part of the XSBridge clang module (module.modulemap only exposes
 * bridge.h): this header is included textually, after xs.h, by C translation
 * units that implement host functions. It must never be imported from Swift.
 */
#ifndef XSB_BRIDGE_XS_H
#define XSB_BRIDGE_XS_H

#include <stdint.h>

/* Create the JS Promise for an in-flight native call. Sets xsResult to the
 * promise, roots its resolve/reject (plus `onToken` if non-NULL — pass a
 * pointer to an argument slot, e.g. &xsArg(1)) in a message record, and
 * returns the call id. Call from inside a C host function, then hand
 * (xsGetContext(the), id) to Swift, which settles later with
 * xsServiceResolve / xsServiceEmit. */
uint32_t xsServicePromise(xsMachine* the, xsSlot* onToken);

/* JSON.stringify(xsArg(index)) as a malloc'd UTF-8 string (free() after
 * handing off to Swift). Uses xsResult as scratch — call it BEFORE
 * xsServicePromise. */
char* xsBridgeArgJSON(xsMachine* the, int index);

/* Part D: call a service on this machine's linked target machine. Creates the
 * Promise on `the` (xsResult), alien-marshals `*args` and posts the request to
 * the target (linked via xsServiceLink); the target's global
 * `__serviceHandler(method, args)` produces the result, marshalled back and
 * used to settle the Promise. Call from inside a consumer host function. */
void xsServiceInvoke(xsMachine* the, const char* method, xsSlot* args);

/* One host function for the snapshot callback table (name = a stable label for
 * the prefix guard, not necessarily the JS property name). */
typedef struct { const char* name; xsCallback callback; } XSBridgeHostFn;

/* Register the process-wide, append-only host-function table used to project /
 * unproject C callbacks across a snapshot. Call once at startup, before any
 * xsBridgeReadSnapshot. Must list every host function that can be reachable
 * from the heap at snapshot time, in a stable order. */
void xsBridgeRegisterHostTable(const XSBridgeHostFn* fns, int count);

#endif /* XSB_BRIDGE_XS_H */
