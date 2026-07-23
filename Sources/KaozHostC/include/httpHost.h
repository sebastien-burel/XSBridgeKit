/*
 * httpHost.h — install the native `__http` networking primitive on a machine.
 *
 * Same invariant as bridge.h: nothing XS-specific crosses to Swift. Used by
 * the JSProvider engine so JS-authored providers can make HTTP requests.
 */
#ifndef TYKAOZ_HTTP_HOST_H
#define TYKAOZ_HTTP_HOST_H

/* Install `__http(request, onChunk)` on the machine's global. Run on the XS
 * thread (via XSEngine.withMachine). Registers no snapshot table. */
void xsBridgeHttpInstall(void* machine);

#endif /* TYKAOZ_HTTP_HOST_H */
