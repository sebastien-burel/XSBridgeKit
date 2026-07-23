/*
 * httpHost.c — a native networking primitive for the XS engine, on the same
 * async+stream bridge as the rest of TyKaoz's host functions.
 *
 * `__http(requestJSON, onChunk)` creates its Promise via xsServicePromise (which
 * also roots `onChunk`), then hands (bridge, id, requestJSON) to the Swift
 * @_cdecl `xsbHttpSend`. Swift performs the request off the XS thread and:
 *   - streams each response chunk back via xsServiceEmit -> onChunk(text)
 *   - settles with xsServiceResolve({status, headers}) on completion / error.
 *
 * This is the low-level primitive a JS `XMLHttpRequest` shim sits on top of, so
 * external LLM providers can be written in JavaScript (JS-first). It installs
 * nothing beyond `__http` and registers no snapshot table (the JSProvider engine
 * is never snapshotted).
 */
#include "xsAll.h"
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"
#include "httpHost.h"

#include <stdlib.h>

/* Implemented in Swift (@_cdecl, resolved at link). */
extern void xsbHttpSend(void* bridge, uint32_t id, const char* requestJSON);

/* __http(request, onChunk) — async request with a streamed-chunk reverse
 * channel. `request` is JSON.stringify'd to {method,url,headers,body}. */
static void xs_http(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    char* json = xsBridgeArgJSON(the, 0);          /* stringify arg0; uses xsResult */
    uint32_t id = xsServicePromise(the, &xsArg(1));  /* roots onChunk */
    xsbHttpSend(bridge, id, json);
    free(json);
}

void xsBridgeHttpInstall(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(1);
        xsTry {
            xsVar(0) = xsNewHostFunction(xs_http, 2);
            xsSet(xsGlobal, xsID("__http"), xsVar(0));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
