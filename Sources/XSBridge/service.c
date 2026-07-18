/*
 * service.c — the machine↔machine "service" peer.
 *
 * A machine calls a service on another machine: it creates a Promise on itself
 * (reusing xsServicePromise's rooting + message list from bridge.c), alien-
 * marshals the args and posts a request worker job to the target machine. The
 * target demarshals, invokes its global __serviceHandler(method, args), alien-
 * marshals the result (or an error) and posts a reply worker job back. The
 * reply reuses bridge.c's unified settle callbacks (ServiceEventResolve /
 * ServiceEventReject) — the machine peer differs from the native (Swift) peer
 * only in its payload flavor (XSB_PAYLOAD_MARSHALLED vs JSON), so the whole
 * settlement path is shared.
 *
 * All value transfer is ALIEN marshalling (self-contained, by name) — so the
 * two machines need no shared preparation (xsCreateMachine, not fxCloneMachine).
 * The transport is mac_xs.c's fxQueueWorkerJob, the same primitive piuService's
 * ServiceThreadSignal mirrors.
 */
#include "xsAll.h"
#include "xs.h"

#include "bridge.h"
#include "bridgeXS.h"
#include "bridgeInternal.h"

#include <stdlib.h>
#include <string.h>

/* Runs on the SERVER machine's thread — demarshals args and invokes the
 * orchestrator. Defined below; referenced by xsServiceInvoke's posted event. */
static void ServiceEventInvoke(void* machine, void* job);

/* Server-side record of an in-flight request: maps a server-local id to the
 * client to reply to, so an async __serviceHandler can settle it later. */
typedef struct ServicePending {
    uint32_t serverId;
    XSBridge* client;
    uint32_t clientCallId;
    struct ServicePending* next;
} ServicePending;

static void ServiceAddPending(XSBridge* server, uint32_t serverId,
                              XSBridge* client, uint32_t clientCallId)
{
    ServicePending* p = (ServicePending*)calloc(1, sizeof(ServicePending));
    p->serverId = serverId;
    p->client = client;
    p->clientCallId = clientCallId;
    p->next = (ServicePending*)server->servicePending;
    server->servicePending = p;
}

/* Unlink and return the pending record for serverId (caller frees), or NULL. */
static ServicePending* ServiceTakePending(XSBridge* server, uint32_t serverId)
{
    ServicePending** pp = (ServicePending**)&server->servicePending;
    while (*pp) {
        if ((*pp)->serverId == serverId) {
            ServicePending* found = *pp;
            *pp = found->next;
            return found;
        }
        pp = &(*pp)->next;
    }
    return NULL;
}

/* Post a reply worker job to the client, settling its Promise via bridge.c's
 * shared machine-peer settle callback (marshalled payload). */
static void ServicePostReply(XSBridge* client, uint32_t clientCallId,
                             int reject, void* blob)
{
    ServiceEvent* r = (ServiceEvent*)calloc(1, sizeof(ServiceEvent));
    r->job.callback = reject ? ServiceEventReject : ServiceEventResolve;
    r->payload = XSB_PAYLOAD_MARSHALLED;
    r->id = clientCallId;
    r->blob = blob;
    fxQueueWorkerJob(client->machine, r);
}

/* Server-side orchestrator: wraps __serviceHandler in a promise so sync and
 * async handlers settle uniformly, then hands the result (or error) back to C
 * via __serviceReply(serverId, value, isError). */
static const char* kServiceOrchestrator =
    "globalThis.__runService = function(sid, method, args) {"
    "  Promise.resolve().then(function() {"
    "    if (typeof globalThis.__serviceHandler !== 'function')"
    "      throw new Error('no __serviceHandler');"
    "    return globalThis.__serviceHandler(method, args);"
    "  }).then(function(v) { __serviceReply(sid, v, false); },"
    "    function(e) { __serviceReply(sid, (e && e.message) || String(e), true); });"
    "};";

/* Client host helper: create the Promise on `the`, marshal args, post the
 * request to this machine's linked service target. Leaves xsResult = the
 * Promise. Must run in a host frame (a consumer host function). */
void xsServiceInvoke(xsMachine* the, const char* method, xsSlot* args)
{
    XSBridge* client = (XSBridge*)xsGetContext(the);
    XSBridge* server = (XSBridge*)client->serviceTarget;
    if (!server) {
        xsUnknownError("no service target linked");
        return;
    }
    uint32_t id = xsServicePromise(the, NULL);  /* roots resolve/reject; xsResult = promise */
    void* blob = xsMarshallAlien(*args);

    ServiceEvent* j = (ServiceEvent*)calloc(1, sizeof(ServiceEvent));
    j->job.callback = ServiceEventInvoke;
    j->payload = XSB_PAYLOAD_MARSHALLED;
    j->client = client;                  /* who to reply to */
    j->id = id;                          /* the client's call id, echoed in the reply */
    j->method = strdup(method ? method : "");
    j->blob = blob;                      /* alien-marshalled args */
    fxQueueWorkerJob(server->machine, j);
}

/* C host function on the server: __serviceReply(serverId, value, isError).
 * Marshals the settled value and posts the reply worker job to the client. */
static void ServiceMessageReply(xsMachine* the)
{
    XSBridge* server = (XSBridge*)xsGetContext(the);
    uint32_t serverId = (uint32_t)xsToInteger(xsArg(0));
    int reject = xsToInteger(xsArg(2)) ? 1 : 0;
    void* blob = xsMarshallAlien(xsArg(1));

    ServicePending* pend = ServiceTakePending(server, serverId);
    if (!pend) { free(blob); return; }

    ServicePostReply(pend->client, pend->clientCallId, reject, blob);
    free(pend);
}

/* Runs on the SERVER machine's thread: demarshal args, register the pending
 * request and invoke __runService(serverId, method, args). The reply is posted
 * later by __serviceReply, so both sync and async handlers work. */
static void ServiceEventInvoke(void* machine, void* job_)
{
    ServiceEvent* j = (ServiceEvent*)job_;
    XSBridge* server = (XSBridge*)xsGetContext((xsMachine*)machine);
    uint32_t serverId = ++server->nextId;
    int posted = 0;

    ServiceAddPending(server, serverId, j->client, j->id);

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(4);
        xsTry {
            xsVar(0) = xsDemarshallAlien(j->blob);            /* args */
            xsVar(1) = xsGet(xsGlobal, xsID("__runService"));
            xsVar(2) = xsInteger((int)serverId);
            xsVar(3) = xsString(j->method);
            xsCallFunction3(xsVar(1), xsUndefined, xsVar(2), xsVar(3), xsVar(0));
            posted = 1;
        }
        xsCatch {
        }
        xsBridgeDrainPromises(the);
    }
    xsEndHost((xsMachine*)machine);

    free(j->blob);
    free(j->method);

    /* Orchestrator missing / threw before scheduling: settle as reject now. */
    if (!posted) {
        ServicePending* pend = ServiceTakePending(server, serverId);
        if (pend) {
            ServicePostReply(pend->client, pend->clientCallId, 1, NULL);
            free(pend);
        }
    }
    /* mac_xs.c frees j */
}

/* Flat API: link `clientMachine` to call services on `serverMachine`. */
void xsServiceLink(void* clientMachine, void* serverMachine)
{
    XSBridge* c = (XSBridge*)((txMachine*)clientMachine)->context;
    XSBridge* s = (XSBridge*)((txMachine*)serverMachine)->context;
    c->serviceTarget = s;
}

/* Install the service-server plumbing (__serviceReply host function + the
 * __runService orchestrator) on `serverMachine`. The consumer then sets its own
 * global __serviceHandler(method, args) (may be sync or return a Promise). */
void xsServiceInstallServer(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(1);
        xsTry {
            xsVar(0) = xsNewHostFunction(ServiceMessageReply, 3);
            xsSet(xsGlobal, xsID("__serviceReply"), xsVar(0));
            xsCall1(xsGlobal, xsID("eval"), xsString(kServiceOrchestrator));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
