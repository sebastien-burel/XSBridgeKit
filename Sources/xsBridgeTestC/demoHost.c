/*
 * demoHost.c — C side of the demo host (echo / stream / fail / add).
 *
 * The regression pattern for consumer host functions: each JS-callable entry
 * marshals its arguments to plain C values, creates its Promise via
 * xsBridgePromise (which roots resolve/reject in the bridge), and hands
 * (bridge, id, params) to its Swift @_cdecl counterpart in DemoHost.swift.
 * Swift settles later with xsBridgeComplete / xsBridgeEmitToken.
 */
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"
#include "demoHost.h"

#include <stdlib.h>
#include <string.h>

/* Implemented in Swift (@_cdecl in DemoHost.swift). */
extern double xsbDemoAdd(double a, double b);
extern void xsbDemoEcho(void* bridge, uint32_t id, const char* json);
extern void xsbDemoFail(void* bridge, uint32_t id);
extern void xsbDemoStream(void* bridge, uint32_t id);

/* host.add(a, b) — synchronous JS -> Swift -> JS. */
static void xs_demo_add(xsMachine* the)
{
    double a = xsToNumber(xsArg(0));
    double b = xsToNumber(xsArg(1));
    xsResult = xsNumber(xsbDemoAdd(a, b));
}

/* host.echo(x) — async round trip: x goes to Swift as JSON and comes back. */
static void xs_demo_echo(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    xsResult = xsCall1(xsGet(xsGlobal, xsID("JSON")), xsID("stringify"), xsArg(0));
    char* json = strdup(xsToString(xsResult));
    uint32_t id = xsBridgePromise(the, NULL);   /* xsResult = the promise */
    xsbDemoEcho(bridge, id, json);
    free(json);
}

/* host.fail() — async reject path. */
static void xs_demo_fail(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    uint32_t id = xsBridgePromise(the, NULL);
    xsbDemoFail(bridge, id);
}

/* host.stream(prompt, onToken) — async with the reverse token channel. */
static void xs_demo_stream(xsMachine* the)
{
    void* bridge = xsGetContext(the);
    uint32_t id = xsBridgePromise(the, &xsArg(1));   /* roots onToken too */
    xsbDemoStream(bridge, id);
}

void xsBridgeTestInstall(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(2);
        xsTry {
            xsVar(0) = xsNewObject();
            xsSet(xsGlobal, xsID("host"), xsVar(0));

            xsVar(1) = xsNewHostFunction(xs_demo_echo, 1);
            xsSet(xsVar(0), xsID("echo"), xsVar(1));

            xsVar(1) = xsNewHostFunction(xs_demo_stream, 2);
            xsSet(xsVar(0), xsID("stream"), xsVar(1));

            xsVar(1) = xsNewHostFunction(xs_demo_fail, 0);
            xsSet(xsVar(0), xsID("fail"), xsVar(1));

            xsVar(1) = xsNewHostFunction(xs_demo_add, 2);
            xsSet(xsVar(0), xsID("add"), xsVar(1));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
