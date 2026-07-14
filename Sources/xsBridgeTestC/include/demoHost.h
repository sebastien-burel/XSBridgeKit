/*
 * demoHost.h — flat C API of the demo host, exposed to Swift.
 *
 * Same invariant as bridge.h: nothing XS-specific crosses this header.
 */
#ifndef XSB_DEMO_HOST_H
#define XSB_DEMO_HOST_H

/* Install the demo host functions (host.echo/stream/fail/add) on the machine.
 * Must run on the XS thread (call via XSEngine.withMachine). */
void xsBridgeTestInstall(void* machine);

#endif /* XSB_DEMO_HOST_H */
