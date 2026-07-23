/*
 * jsProviderHost.c — the JS→Swift event channel for a JSProvider engine.
 *
 * A provider written in JavaScript streams its results by calling these host
 * functions; each hands off to a Swift @_cdecl that feeds the provider's
 * AsyncThrowingStream<StreamEvent>. The JSProvider is recovered Swift-side from
 * the bridge context (xsBridgeGetContext).
 *
 *   __emit(event)          one StreamEvent as a JS object (mapped Swift-side)
 *   __done()               the chat finished normally
 *   __providerError(msg)   the chat threw / rejected
 *
 * These are synchronous notifications (no Promise): fire-and-return.
 */
#include "xsAll.h"
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"
#include "jsProviderHost.h"

#include <stdlib.h>

/* Implemented in Swift (@_cdecl, resolved at link). */
extern void xsbJSProviderEmit(void* bridge, const char* eventJSON);
extern void xsbJSProviderDone(void* bridge);
extern void xsbJSProviderError(void* bridge, const char* message);

static void xs_emit(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = xsBridgeArgJSON(the, 0);
    xsbJSProviderEmit(bridge, json);
    free(json);
}

static void xs_done(xsMachine* the)
{
    xsbJSProviderDone(xsGetContext(the));
}

static void xs_error(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    xsbJSProviderError(bridge, xsToString(xsArg(0)));
}

void xsBridgeJSProviderInstall(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(1);
        xsTry {
            xsVar(0) = xsNewHostFunction(xs_emit, 1);
            xsSet(xsGlobal, xsID("__emit"), xsVar(0));
            xsVar(0) = xsNewHostFunction(xs_done, 0);
            xsSet(xsGlobal, xsID("__done"), xsVar(0));
            xsVar(0) = xsNewHostFunction(xs_error, 1);
            xsSet(xsGlobal, xsID("__providerError"), xsVar(0));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
