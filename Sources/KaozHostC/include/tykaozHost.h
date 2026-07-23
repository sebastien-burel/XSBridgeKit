/*
 * tykaozHost.h — flat C API of TyKaoz's host functions, exposed to Swift.
 *
 * Same invariant as XSBridgeKit's bridge.h: nothing XS-specific crosses here.
 * Swift only sees the opaque machine handle (void*).
 */
#ifndef TYKAOZ_HOST_H
#define TYKAOZ_HOST_H

/* Install TyKaoz's host.* functions on the machine and register the snapshot
 * host table. Must run on the XS thread (call via XSEngine.withMachine). */
void xsBridgeTyKaozInstall(void* machine);

/* Register the snapshot host table only (no machine) — call before restoring
 * a snapshot. */
void xsBridgeTyKaozRegister(void);

#endif /* TYKAOZ_HOST_H */
