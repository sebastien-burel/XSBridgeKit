/*
 * demoHost.h — flat C API of the demo host, exposed to Swift.
 *
 * Same invariant as bridge.h: nothing XS-specific crosses this header.
 */
#ifndef XSB_DEMO_HOST_H
#define XSB_DEMO_HOST_H

/* Install the demo host functions (print + host.echo/stream/fail/add) on the
 * machine and reset the print capture. Must run on the XS thread (call via
 * XSEngine.withMachine). */
void xsBridgeTestInstall(void* machine);

/* Captured print() output since the last install (global store — the harness
 * runs one printing machine at a time). */
int xsBridgeTestOutputCount(void);
const char* xsBridgeTestOutputAt(int index);

#endif /* XSB_DEMO_HOST_H */
