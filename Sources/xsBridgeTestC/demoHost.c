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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Implemented in Swift (@_cdecl in DemoHost.swift). */
extern double xsbDemoAdd(double a, double b);
extern void xsbDemoEcho(void* bridge, uint32_t id, const char* json);
extern void xsbDemoFail(void* bridge, uint32_t id);
extern void xsbDemoStream(void* bridge, uint32_t id);

/* ---- print + capture (harness assertions) --------------------------------
 * One global store, reset at each install: the harness runs one printing
 * machine at a time, and every makeEngine() reinstalls (so re-arms) it. */

static char** gOutputs;
static size_t gOutputCount;
static size_t gOutputCap;

static void xs_demo_reset_outputs(void)
{
    for (size_t i = 0; i < gOutputCount; i++)
        free(gOutputs[i]);
    free(gOutputs);
    gOutputs = NULL;
    gOutputCount = gOutputCap = 0;
}

int xsBridgeTestOutputCount(void)
{
    return (int)gOutputCount;
}

const char* xsBridgeTestOutputAt(int index)
{
    if (index < 0 || index >= (int)gOutputCount)
        return NULL;
    return gOutputs[index];
}

/* print(x) — logs to stdout and captures the value for the harness to assert. */
static void xs_demo_print(xsMachine* the)
{
    const char* s = (xsToInteger(xsArgc) > 0) ? xsToString(xsArg(0)) : "";
    if (gOutputCount == gOutputCap) {
        size_t ncap = gOutputCap ? gOutputCap * 2 : 8;
        gOutputs = (char**)realloc(gOutputs, ncap * sizeof(char*));
        gOutputCap = ncap;
    }
    gOutputs[gOutputCount++] = strdup(s);
    fprintf(stdout, "%s\n", s);
}

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
    char* json = xsBridgeArgJSON(the, 0);
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

/* host.callService(method, args) — Part D: calls a service on the linked target
 * machine; args and the result cross as alien-marshalled values. */
static void xs_demo_service_call(xsMachine* the)
{
    const char* method = xsToString(xsArg(0));
    xsBridgeServiceCall(the, method, &xsArg(1));   /* xsResult = the promise */
}

void xsBridgeTestInstall(void* machine)
{
    xs_demo_reset_outputs();
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(2);
        xsTry {
            xsVar(0) = xsNewHostFunction(xs_demo_print, 1);
            xsSet(xsGlobal, xsID("print"), xsVar(0));

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

            xsVar(1) = xsNewHostFunction(xs_demo_service_call, 2);
            xsSet(xsVar(0), xsID("callService"), xsVar(1));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
