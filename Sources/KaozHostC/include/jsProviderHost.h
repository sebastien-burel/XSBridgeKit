/*
 * jsProviderHost.h — install the JS→Swift event channel for a JSProvider engine.
 */
#ifndef TYKAOZ_JSPROVIDER_HOST_H
#define TYKAOZ_JSPROVIDER_HOST_H

/* Install __emit / __done / __providerError on the machine's global. Run on the
 * XS thread (via XSEngine.withMachine). Registers no snapshot table. */
void xsBridgeJSProviderInstall(void* machine);

#endif /* TYKAOZ_JSPROVIDER_HOST_H */
