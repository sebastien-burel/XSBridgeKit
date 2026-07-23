/*
 * service.c — the machine↔machine "service" peer, driven from JS (the piu
 * model): `new Thread(name)` spawns a child engine and `new Service(thread,
 * module)` returns a Proxy over it. A method call marshals its args (alien) and
 * posts a request worker job to the child machine; the child imports `module`
 * and calls its default export's method, then alien-marshals the result (or an
 * error) and posts a reply worker job back. The reply reuses settle.c's settle
 * callbacks (ServiceEventResolve / ServiceEventReject) — the machine peer differs
 * from the native (Swift) peer only in its payload flavor (XSB_PAYLOAD_MARSHALLED
 * vs JSON) and in that its Promise is created in JS, not by xsServicePromise.
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

/* Free every server-side in-flight request record (machine delete). Any client
 * awaiting these requests never gets a reply — but that Promise dies with the
 * whole graph the caller is tearing down, so there is nothing to settle. */
void xsServiceFreePending(XSBridge* bridge)
{
    ServicePending* p = (ServicePending*)bridge->servicePending;
    while (p) {
        ServicePending* n = p->next;
        free(p);
        p = n;
    }
    bridge->servicePending = NULL;
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


/* ---------------------------------------------------------------------------
 * JS-initiated threads: `new Thread(name)` spawns a child engine.
 *
 * Machine creation is inherently native (a machine owns a thread + run loop),
 * so it stays a primitive — but WHICH engine, how many, and how they are wired
 * is decided entirely in the script. The child engine itself is built by a
 * consumer-supplied factory (the socle installs no host capabilities), so a
 * child gets exactly the host surface its consumer wants (plus xsThreadInstall
 * to spawn/serve recursively). A Thread JS object holds the child machine as
 * host data; its host destructor tears the child down when the object is GC'd.
 * ------------------------------------------------------------------------- */

static XSThreadCreate gThreadCreate;
static XSThreadDestroy gThreadDestroy;

void xsBridgeRegisterThreadFactory(XSThreadCreate create, XSThreadDestroy destroy)
{
    gThreadCreate = create;
    gThreadDestroy = destroy;
}

/* Host destructor: fires when the Thread host object is collected. `data` is the
 * child machine handed back by the factory; hand it to the factory to destroy. */
static void ThreadDelete(void* data)
{
    if (data && gThreadDestroy)
        gThreadDestroy(data);
}

/* __spawnThread(name) — create a child engine via the registered factory and
 * return a host object that owns it (host data = child machine, destructor =
 * ThreadDelete). Runs on the parent's XS thread; the factory creates the child
 * synchronously and returns its machine. The `Thread` prelude wraps this so
 * `new Thread(name)` yields the host object (a constructor returning an object
 * returns that object). */
static void ThreadSpawn(xsMachine* the)
{
    if (!gThreadCreate)
        xsUnknownError("no thread factory registered");
    char* name = (xsToInteger(xsArgc) > 0) ? strdup(xsToString(xsArg(0))) : NULL;
    void* child = gThreadCreate(name ? name : "");
    free(name);
    if (!child)
        xsUnknownError("thread creation failed");
    xsResult = xsNewHostObject(ThreadDelete);
    xsSetHostData(xsResult, child);
}

/* ---------------------------------------------------------------------------
 * Service: JS proxy over a child engine — `new Service(thread, module)`.
 *
 * A Service binds (this machine as client, a child Thread's machine as server, a
 * module specifier). Method access on the returned Proxy creates a Promise IN JS
 * and hands its resolve/reject to __serviceInvoke, which roots them in a
 * ServiceMessage (reusing settle.c) and posts the marshalled args to the child.
 * The child imports `module`, calls its default export's method, then replies —
 * settled through the same ServiceEventResolve/Reject path as the native peer.
 * The only per-peer difference from the native trio is that resolve/reject come
 * from JS here (the Promise is created in the script), not from xsServicePromise.
 * ------------------------------------------------------------------------- */

typedef struct ServiceProxy {
    XSBridge* client;    /* the machine holding this Service */
    XSBridge* server;    /* the child machine to call */
    char* module;        /* module specifier imported in the child (owned) */
} ServiceProxy;

/* Child-side request handler (runs on the server machine): defined below. */
static void ServiceEventInvokeModule(void* machine, void* job);

/* Host destructor for a Service proxy record. */
static void ServiceProxyDelete(void* data)
{
    ServiceProxy* proxy = (ServiceProxy*)data;
    if (proxy) {
        free(proxy->module);
        free(proxy);
    }
}

/* __serviceCreate(thread, module) — build a proxy record bound to the child
 * engine held by `thread`, and return a host object owning it. */
static void ServiceProxyCreate(xsMachine* the)
{
    void* childMachine = xsGetHostData(xsArg(0));
    if (!childMachine)
        xsUnknownError("Service: argument is not a Thread");
    ServiceProxy* proxy = (ServiceProxy*)calloc(1, sizeof(ServiceProxy));
    proxy->client = (XSBridge*)xsGetContext(the);
    proxy->server = (XSBridge*)((txMachine*)childMachine)->context;
    proxy->module = strdup(xsToString(xsArg(1)));
    xsResult = xsNewHostObject(ServiceProxyDelete);
    xsSetHostData(xsResult, proxy);
}

/* __serviceInvoke(handle, method, args, resolve, reject) — open a call with the
 * JS-created resolve/reject (rooted in a ServiceMessage, reusing settle.c),
 * marshal the args and post a request to the child keyed by module + method. */
static void ServiceProxyInvoke(xsMachine* the)
{
    ServiceProxy* proxy = (ServiceProxy*)xsGetHostData(xsArg(0));
    if (!proxy)
        xsUnknownError("Service: invalid proxy");
    XSBridge* client = proxy->client;

    ServiceMessage* rec = (ServiceMessage*)calloc(1, sizeof(ServiceMessage));
    rec->id = ++client->nextId;
    rec->resolve = xsArg(3);
    rec->reject = xsArg(4);
    fxRemember(the, &rec->resolve);
    fxRemember(the, &rec->reject);
    client->rememberCount += 2;
    rec->next = client->messages;
    client->messages = rec;

    void* blob = xsMarshallAlien(xsArg(2));

    ServiceEvent* j = (ServiceEvent*)calloc(1, sizeof(ServiceEvent));
    j->job.callback = ServiceEventInvokeModule;
    j->payload = XSB_PAYLOAD_MARSHALLED;
    j->client = client;
    j->id = rec->id;
    j->method = strdup(xsToString(xsArg(1)));
    j->module = strdup(proxy->module);
    j->blob = blob;
    fxQueueWorkerJob(proxy->server->machine, j);
}

/* Runs on the SERVER (child) machine's thread: demarshal args, register the
 * pending request and invoke __runModuleService(serverId, module, method, args),
 * which imports the module and calls its default export. Reply posted later. */
static void ServiceEventInvokeModule(void* machine, void* job_)
{
    ServiceEvent* j = (ServiceEvent*)job_;
    XSBridge* server = (XSBridge*)xsGetContext((xsMachine*)machine);
    uint32_t serverId = ++server->nextId;
    int posted = 0;

    ServiceAddPending(server, serverId, j->client, j->id);

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(5);
        xsTry {
            xsVar(0) = xsDemarshallAlien(j->blob);              /* args */
            xsVar(1) = xsGet(xsGlobal, xsID("__runModuleService"));
            xsVar(2) = xsInteger((int)serverId);
            xsVar(3) = xsString(j->module);
            xsVar(4) = xsString(j->method);
            xsCallFunction4(xsVar(1), xsUndefined, xsVar(2), xsVar(3), xsVar(4), xsVar(0));
            posted = 1;
        }
        xsCatch {
        }
        xsBridgeDrainPromises(the);
    }
    xsEndHost((xsMachine*)machine);

    free(j->blob);
    free(j->method);
    free(j->module);

    if (!posted) {
        ServicePending* pend = ServiceTakePending(server, serverId);
        if (pend) {
            ServicePostReply(pend->client, pend->clientCallId, 1, NULL);
            free(pend);
        }
    }
}

/* JS preludes: the `Thread` wrapper, the `Service` proxy factory, and the
 * child-side module orchestrator (imports the module, calls its default export,
 * replies via __serviceReply). */
static const char* kThreadServicePrelude =
    "globalThis.Thread = function Thread(name) { return __spawnThread(name); };"
    "globalThis.Service = function Service(thread, module) {"
    "  if ((module.charAt(0) === '.') && globalThis.__moduleBase)"
    "    module = globalThis.__moduleBase + '/' + module;"   /* child realpath()s the '.'/'..' away */
    "  const handle = __serviceCreate(thread, module);"
    "  const handler = {"
    "    thread: thread, handle: handle,"   /* keep the child engine + proxy record reachable */
    "    get(target, key) {"
    "      return function (args) {"
    "        return new Promise(function (resolve, reject) {"
    "          __serviceInvoke(handle, key, args, resolve, reject);"
    "        });"
    "      };"
    "    }"
    "  };"
    "  return new Proxy(handler, handler);"
    "};"
    "globalThis.__runModuleService = function (sid, module, method, args) {"
    "  Promise.resolve().then(function () { return import(module); })"
    "    .then(function (m) {"
    "      const svc = (m && m.default) || m;"
    "      if (typeof svc[method] !== 'function') throw new Error('no service method ' + method);"
    "      return svc[method](args);"
    "    })"
    "    .then(function (v) { __serviceReply(sid, v, false); },"
    "          function (e) { __serviceReply(sid, (e && e.message) || String(e), true); });"
    "};";

/* Install the full Thread/Service surface on `machine`: the spawn + proxy
 * primitives, the `Thread`/`Service` globals, and the server-side reply plumbing
 * (so an engine with xsThreadInstall can both spawn children and serve calls). */
void xsThreadInstall(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsVars(1);
        xsTry {
            xsVar(0) = xsNewHostFunction(ThreadSpawn, 1);
            xsSet(xsGlobal, xsID("__spawnThread"), xsVar(0));
            xsVar(0) = xsNewHostFunction(ServiceProxyCreate, 2);
            xsSet(xsGlobal, xsID("__serviceCreate"), xsVar(0));
            xsVar(0) = xsNewHostFunction(ServiceProxyInvoke, 5);
            xsSet(xsGlobal, xsID("__serviceInvoke"), xsVar(0));
            xsVar(0) = xsNewHostFunction(ServiceMessageReply, 3);
            xsSet(xsGlobal, xsID("__serviceReply"), xsVar(0));
            xsCall1(xsGlobal, xsID("eval"), xsString(kThreadServicePrelude));
        }
        xsCatch {
        }
    }
    xsEndHost((xsMachine*)machine);
}
