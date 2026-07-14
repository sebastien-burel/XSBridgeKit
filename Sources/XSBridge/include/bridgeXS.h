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
 * pointer to an argument slot, e.g. &xsArg(1)) in a pending record, and
 * returns the call id. Call from inside a C host function, then hand
 * (xsGetContext(the), id) to Swift, which settles later with
 * xsBridgeComplete / xsBridgeEmitToken. */
uint32_t xsBridgePromise(xsMachine* the, xsSlot* onToken);

#endif /* XSB_BRIDGE_XS_H */
