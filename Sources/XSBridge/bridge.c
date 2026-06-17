/*
 * bridge.c — the shim between Swift and the XS engine.
 *
 * Phases 0-2: smoke, machine lifecycle + sync eval, sync host function.
 * Phase 3: the asynchronous bridge. A JS Promise is created on the JS side;
 * __nativeCall roots its resolve/reject (xsRemember), dispatches the request to
 * Swift, and Swift settles it later from a background queue by signaling a
 * CFRunLoopSource. The perform callback (on the XS run loop) resolves/rejects,
 * xsForgets, and drains promise jobs to resume the awaiting JS continuation.
 *
 * Invariants: XS is single-threaded (all machine access on the run-loop thread);
 * no xsSlot crosses into Swift (only opaque ids + UTF-8 JSON); every Swift->XS
 * entry is framed by xsBeginHost/xsEndHost with xsTry/xsCatch.
 */
#include "xsAll.h"
#include "xs.h"

#include "bridge.h"

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <CoreFoundation/CoreFoundation.h>

/* ---------------------------------------------------------------------------
 * Platform layer (see Phase 1 notes): minimal standalone impls that xst.h
 * leaves to the host program.
 * ------------------------------------------------------------------------- */

void fxCreateMachinePlatform(txMachine* the)
{
#ifdef mxDebug
  the->connection = mxNoSocket;
#endif
}

void fxDeleteMachinePlatform(txMachine* the)
{
}

void fxQueuePromiseJobs(txMachine* the)
{
    the->promiseJobs = 1;
}

void fxAbort(txMachine* the, int status)
{
    if (XS_DEBUGGER_EXIT == status)
        c_exit(1);
    if (the->exitStatus) /* xsEndHost calls fxAbort! */
        return;
    the->exitStatus = status;
    fxExitToHost(the);
}

txID fxFindModule(txMachine* the, txSlot* realm, txID moduleID, txSlot* slot)
{
    (void)the; (void)realm; (void)moduleID; (void)slot;
    return XS_NO_ID;
}

void fxLoadModule(txMachine* the, txSlot* module, txID moduleID)
{
    (void)the; (void)module; (void)moduleID;
}

void fxInitializeSharedTimers(void) {}
void fxTerminateSharedTimers(void) {}

void* fxScheduleSharedTimer(double timeout, double interval,
                            txSharedTimerCallback callback,
                            void* refcon, int refconSize)
{
    (void)timeout; (void)interval; (void)callback; (void)refcon; (void)refconSize;
    return NULL;
}

void fxUnscheduleSharedTimer(txSharedTimer* timer) { (void)timer; }

void fxRescheduleSharedTimer(txSharedTimer* timer, double timeout, double interval)
{
    (void)timer; (void)timeout; (void)interval;
}

/* ---------------------------------------------------------------------------
 * Bridge state.
 * ------------------------------------------------------------------------- */

/* Kinds of message handed back from Swift to the XS thread. */
enum { XSB_REJECT = 0, XSB_RESOLVE = 1, XSB_TOKEN = 2 };

/* One in-flight async call. resolve/reject/onToken are XS function references
 * kept in C memory and rooted via fxRemember; the record's address must be
 * stable while remembered (the GC root list points at &resolve etc). onToken is
 * present only for streaming calls and lives for the whole call. XS-thread only. */
typedef struct XSPending {
    uint32_t id;
    txSlot resolve;
    txSlot reject;
    txSlot onToken;
    int hasOnToken;
    struct XSPending* next;
} XSPending;

/* A message handed back from a Swift background thread to the XS thread:
 * a streamed token (XSB_TOKEN, keeps the call open) or the final settlement
 * (XSB_RESOLVE / XSB_REJECT). */
typedef struct XSResult {
    uint32_t id;
    int type;
    char* json;         /* token delta / result value as JSON (owned) */
    struct XSResult* next;
} XSResult;

typedef struct XSBridge {
    xsMachine* machine;
    void* swiftContext;     /* opaque XSEngine pointer, for sync host.add */
    uint32_t nextId;
    XSPending* pending;    /* XS-thread only */

    pthread_mutex_t lock;
    XSResult* results;     /* guarded by lock; producer = bg threads */
    CFRunLoopSourceRef source;
    CFRunLoopRef runloop;

    uint32_t rememberCount; /* leak accounting */
    uint32_t forgetCount;

    char** outputs;         /* captured print() output, XS-thread only */
    size_t outputCount;
    size_t outputCap;
} XSBridge;

/* Implemented in Swift (@_cdecl), resolved at the final executable link.
 * Both route a (key, JSON params) to the consumer's HostBridge — the C layer
 * knows nothing about specific host capabilities (echo, tools, chat, …). */
extern void xsb_dispatch(void* bridge, uint32_t id,
                         const char* key, const char* json);
extern char* xsb_dispatch_sync(void* bridge, const char* key, const char* json);

static void xsb_perform(void* info);

/* ---------------------------------------------------------------------------
 * Host functions — generic primitives only. The consumer installs its host.*
 * convenience wrappers (around __nativeCall / __nativeCallSync) via a prelude.
 * ------------------------------------------------------------------------- */

/* __nativeCall(key, params, resolve, reject[, onToken]) — the async entry.
 * Roots resolve/reject (+onToken), records the call by id, and posts it to Swift. */
static void fx_native_call(xsMachine* the)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);

    /* Root resolve/reject (and onToken, for streaming) BEFORE any allocation
     * that could trigger GC, so the collector tracks (and relocates) these
     * references. onToken lives for the whole call (the reverse channel). */
    int argc = (int)xsToInteger(xsArgc);
    XSPending* rec = (XSPending*)calloc(1, sizeof(XSPending));
    rec->id = ++bridge->nextId;
    rec->resolve = xsArg(2);
    rec->reject = xsArg(3);
    fxRemember(the, &rec->resolve);
    fxRemember(the, &rec->reject);
    bridge->rememberCount += 2;
    if (argc > 4 && xsTypeOf(xsArg(4)) == xsReferenceType) {
        rec->onToken = xsArg(4);
        fxRemember(the, &rec->onToken);
        rec->hasOnToken = 1;
        bridge->rememberCount += 1;
    }
    rec->next = bridge->pending;
    bridge->pending = rec;

    xsVars(1);
    char* key = strdup(xsToString(xsArg(0)));
    xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
    xsResult = xsCall1(xsVar(0), xsID("stringify"), xsArg(1));
    char* json = strdup(xsToString(xsResult));

    /* Swift copies key/json synchronously, then works on a background queue. */
    xsb_dispatch(bridge, rec->id, key, json);
    free(key);
    free(json);
}

/* __nativeCallSync(key, params) — synchronous JS -> Swift -> JS. Returns the
 * JSON result the host produced (parsed back into a JS value). */
static void fx_native_call_sync(xsMachine* the)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);
    xsVars(1);
    char* key = strdup(xsToString(xsArg(0)));
    xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
    xsResult = xsCall1(xsVar(0), xsID("stringify"), xsArg(1));
    char* json = strdup(xsToString(xsResult));

    char* result = xsb_dispatch_sync(bridge, key, json); /* malloc'd JSON or NULL */
    free(key);
    free(json);

    if (result) {
        xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
        xsResult = xsCall1(xsVar(0), xsID("parse"), xsString(result));
        free(result);
    } else {
        xsResult = xsUndefined;
    }
}

static void xsb_capture_output(XSBridge* bridge, const char* s)
{
    if (bridge->outputCount == bridge->outputCap) {
        size_t ncap = bridge->outputCap ? bridge->outputCap * 2 : 8;
        bridge->outputs = (char**)realloc(bridge->outputs, ncap * sizeof(char*));
        bridge->outputCap = ncap;
    }
    bridge->outputs[bridge->outputCount++] = strdup(s);
}

/* print(x) — logs to stdout and captures the value for the harness to assert. */
static void fx_print(xsMachine* the)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);
    const char* s = (xsToInteger(xsArgc) > 0) ? xsToString(xsArg(0)) : "";
    xsb_capture_output(bridge, s);
    fprintf(stdout, "%s\n", s);
}

static void xsb_install_host(xsMachine* machine)
{
    xsBeginHost(machine);
    {
        xsVars(2);
        xsTry {
            /* Empty host object; the consumer's prelude installs host.* methods. */
            xsVar(0) = xsNewObject();
            xsSet(xsGlobal, xsID("host"), xsVar(0));

            xsVar(1) = xsNewHostFunction(fx_native_call, 4);
            xsSet(xsGlobal, xsID("__nativeCall"), xsVar(1));

            xsVar(1) = xsNewHostFunction(fx_native_call_sync, 2);
            xsSet(xsGlobal, xsID("__nativeCallSync"), xsVar(1));

            xsVar(1) = xsNewHostFunction(fx_print, 1);
            xsSet(xsGlobal, xsID("print"), xsVar(1));
        }
        xsCatch {
        }
    }
    xsEndHost(machine);
}

/* ---------------------------------------------------------------------------
 * Run-loop perform: settle promises on the XS thread.
 * ------------------------------------------------------------------------- */

static XSPending* xsb_unlink_pending(XSBridge* bridge, uint32_t id)
{
    XSPending** addr = &bridge->pending;
    XSPending* p;
    while ((p = *addr)) {
        if (p->id == id) {
            *addr = p->next;
            return p;
        }
        addr = &p->next;
    }
    return NULL;
}

static XSPending* xsb_find_pending(XSBridge* bridge, uint32_t id)
{
    for (XSPending* p = bridge->pending; p; p = p->next)
        if (p->id == id)
            return p;
    return NULL;
}

static void xsb_perform(void* info)
{
    XSBridge* bridge = (XSBridge*)info;

    /* Detach the whole batch under the lock, then settle without holding it. */
    pthread_mutex_lock(&bridge->lock);
    XSResult* batch = bridge->results;
    bridge->results = NULL;
    pthread_mutex_unlock(&bridge->lock);
    if (!batch)
        return;

    xsBeginHost(bridge->machine);
    {
        xsVars(2);
        XSResult* r = batch;
        while (r) {
            XSResult* next = r->next;
            if (r->type == XSB_TOKEN) {
                /* Reverse channel: invoke onToken(delta), keep the call open. */
                XSPending* rec = xsb_find_pending(bridge, r->id);
                if (rec && rec->hasOnToken) {
                    xsTry {
                        xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
                        xsVar(1) = xsCall1(xsVar(0), xsID("parse"), xsString(r->json));
                        xsCallFunction1(xsAccess(rec->onToken), xsUndefined, xsVar(1));
                    }
                    xsCatch {
                    }
                }
            } else {
                /* Final settlement: resolve/reject, then forget all roots. */
                XSPending* rec = xsb_unlink_pending(bridge, r->id);
                if (rec) {
                    xsTry {
                        xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
                        xsVar(1) = xsCall1(xsVar(0), xsID("parse"), xsString(r->json));
                        if (r->type == XSB_RESOLVE)
                            xsCallFunction1(xsAccess(rec->resolve), xsUndefined, xsVar(1));
                        else
                            xsCallFunction1(xsAccess(rec->reject), xsUndefined, xsVar(1));
                    }
                    xsCatch {
                    }
                    fxForget(the, &rec->resolve);
                    fxForget(the, &rec->reject);
                    bridge->forgetCount += 2;
                    if (rec->hasOnToken) {
                        fxForget(the, &rec->onToken);
                        bridge->forgetCount += 1;
                    }
                    free(rec);
                }
            }
            free(r->json);
            free(r);
            r = next;
        }
        /* Drain promise jobs so the `await` continuations resume. */
        xsTry {
            while (the->promiseJobs) {
                the->promiseJobs = 0;
                fxRunPromiseJobs(the);
            }
        }
        xsCatch {
        }
    }
    xsEndHost(bridge->machine);
}

/* ---------------------------------------------------------------------------
 * Machine lifecycle.
 * ------------------------------------------------------------------------- */

void* xsb_create_machine(void)
{
    xsCreation creation = {
        16 * 1024 * 1024,   /* initialChunkSize */
        16 * 1024 * 1024,   /* incrementalChunkSize */
        1 * 1024 * 1024,    /* initialHeapCount */
        1 * 1024 * 1024,    /* incrementalHeapCount */
        256 * 1024,         /* stackCount */
        1024,               /* initialKeyCount */
        1024,               /* incrementalKeyCount */
        1993,               /* nameModulo */
        127,                /* symbolModulo */
        64 * 1024,          /* parserBufferSize */
        1993,               /* parserTableModulo */
    };

    XSBridge* bridge = (XSBridge*)calloc(1, sizeof(XSBridge));
    xsMachine* machine = xsCreateMachine(&creation, "XSBridge", bridge);
    if (!machine) {
        free(bridge);
        return NULL;
    }
    bridge->machine = machine;
    pthread_mutex_init(&bridge->lock, NULL);

    CFRunLoopSourceContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    ctx.info = bridge;
    ctx.perform = xsb_perform;
    bridge->source = CFRunLoopSourceCreate(NULL, 0, &ctx);
    bridge->runloop = CFRunLoopGetCurrent();
    CFRetain(bridge->runloop);
    CFRunLoopAddSource(bridge->runloop, bridge->source, kCFRunLoopDefaultMode);

    xsb_install_host(machine);
    return machine;
}

void xsb_delete_machine(void* machine)
{
    if (!machine)
        return;
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    xsDeleteMachine((xsMachine*)machine);

    if (bridge->source) {
        CFRunLoopRemoveSource(bridge->runloop, bridge->source, kCFRunLoopDefaultMode);
        CFRunLoopSourceInvalidate(bridge->source);
        CFRelease(bridge->source);
    }
    if (bridge->runloop)
        CFRelease(bridge->runloop);

    XSPending* p = bridge->pending;
    while (p) {
        XSPending* n = p->next;
        free(p);
        p = n;
    }
    XSResult* r = bridge->results;
    while (r) {
        XSResult* n = r->next;
        free(r->json);
        free(r);
        r = n;
    }
    pthread_mutex_destroy(&bridge->lock);
    for (size_t i = 0; i < bridge->outputCount; i++)
        free(bridge->outputs[i]);
    free(bridge->outputs);
    free(bridge);
}

void xsb_set_context(void* machine, void* context)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    bridge->swiftContext = context;
}

/* The opaque Swift context, recovered from the bridge pointer that the async
 * dispatch callbacks receive (so they can find the owning engine/HostBridge). */
void* xsb_context_of(void* bridge)
{
    return ((XSBridge*)bridge)->swiftContext;
}

/* ---------------------------------------------------------------------------
 * Called from Swift background threads.
 * ------------------------------------------------------------------------- */

static void xsb_enqueue(XSBridge* bridge, uint32_t id, int type, const char* json)
{
    XSResult* r = (XSResult*)malloc(sizeof(XSResult));
    r->id = id;
    r->type = type;
    r->json = strdup(json ? json : "null");
    r->next = NULL;

    pthread_mutex_lock(&bridge->lock);
    XSResult** tail = &bridge->results;
    while (*tail)
        tail = &(*tail)->next;
    *tail = r;
    pthread_mutex_unlock(&bridge->lock);

    CFRunLoopSourceSignal(bridge->source);
    CFRunLoopWakeUp(bridge->runloop);
}

void xsb_emit_token(void* bridge, uint32_t id, const char* json)
{
    xsb_enqueue((XSBridge*)bridge, id, XSB_TOKEN, json);
}

void xsb_complete(void* bridge, uint32_t id, int success, const char* json)
{
    xsb_enqueue((XSBridge*)bridge, id, success ? XSB_RESOLVE : XSB_REJECT, json);
}

/* ---------------------------------------------------------------------------
 * Introspection for the harness.
 * ------------------------------------------------------------------------- */

int xsb_pending_count(void* machine)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    int n = 0;
    for (XSPending* p = bridge->pending; p; p = p->next)
        n++;
    return n;
}

/* Force a full garbage collection on the XS thread. Used by the stress test to
 * prove that in-flight resolve/reject/onToken roots survive collection. */
void xsb_collect_garbage(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsCollectGarbage();
    }
    xsEndHost((xsMachine*)machine);
}

void xsb_debug_counts(void* machine, uint32_t* remembered, uint32_t* forgotten)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    if (remembered) *remembered = bridge->rememberCount;
    if (forgotten) *forgotten = bridge->forgetCount;
}

int xsb_output_count(void* machine)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    return (int)bridge->outputCount;
}

const char* xsb_output_at(void* machine, int index)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    if (index < 0 || index >= (int)bridge->outputCount)
        return NULL;
    return bridge->outputs[index];
}

/* ---------------------------------------------------------------------------
 * Phase 0-1 entry points.
 * ------------------------------------------------------------------------- */

int32_t xsb_smoke(void)
{
    return 42;
}

void xsb_free(char* s)
{
    free(s);
}

int xsb_eval(void* machine, const char* src, char** out_json, char** out_err)
{
    int ok = 0;
    *out_json = NULL;
    *out_err = NULL;

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(1);
        xsTry {
            xsResult = xsCall1(xsGlobal, xsID("eval"), xsString(src));
            xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
            xsResult = xsCall1(xsVar(0), xsID("stringify"), xsResult);
            if (xsTypeOf(xsResult) == xsUndefinedType)
                *out_json = strdup("undefined");
            else
                *out_json = strdup(xsToString(xsResult));
            ok = 1;
        }
        xsCatch {
            *out_err = strdup(xsToString(xsException));
            ok = 0;
        }
        /* Drain promise jobs queued by the script — an async function's body up
         * to its first await, or an already-resolved .then chain — so they run
         * within this eval instead of waiting for an async host completion that
         * a pure (host-call-free) agent never makes. Mirrors xsb_perform.
         * Nested scope so xsTry's __JUMP__ does not clash with the eval try. */
        {
            xsTry {
                while (the->promiseJobs) {
                    the->promiseJobs = 0;
                    fxRunPromiseJobs(the);
                }
            }
            xsCatch {
            }
        }
    }
    xsEndHost((xsMachine*)machine);

    return ok;
}

/* DEBUG */

#ifdef mxDebug

void fxConnect(txMachine* the)
{
  if (!c_strcmp(the->name, "xst_fuzz"))
    return;
  if (!c_strcmp(the->name, "xst_fuzz_oss"))
    return;
#ifdef mxMultipleThreads
  if (!c_strcmp(the->name, "xst262"))
    return;
  if (!c_strcmp(the->name, "xst-agent"))
    return;
#endif
  char name[256];
  char* colon;
  int port;
#if mxWindows
  if (GetEnvironmentVariable("XSBUG_HOST", name, sizeof(name))) {
#else
  colon = getenv("XSBUG_HOST");
  if ((colon) && (c_strlen(colon) + 1 < sizeof(name))) {
    c_strcpy(name, colon);
#endif
    colon = strchr(name, ':');
    if (colon == NULL)
      port = 5002;
    else {
      *colon = 0;
      colon++;
      port = strtol(colon, NULL, 10);
    }
  }
  else {
    strcpy(name, "localhost");
    port = 5002;
  }
#if mxWindows
{
  WSADATA wsaData;
  struct hostent *host;
  struct sockaddr_in address;
  unsigned long flag;
  if (WSAStartup(0x202, &wsaData) == SOCKET_ERROR)
    return;
  host = gethostbyname(name);
  if (!host)
    goto bail;
  memset(&address, 0, sizeof(address));
  address.sin_family = AF_INET;
  memcpy(&(address.sin_addr), host->h_addr, host->h_length);
    address.sin_port = htons(port);
  the->connection = socket(AF_INET, SOCK_STREAM, 0);
  if (the->connection == INVALID_SOCKET)
    return;
    flag = 1;
    ioctlsocket(the->connection, FIONBIO, &flag);
  if (connect(the->connection, (struct sockaddr*)&address, sizeof(address)) == SOCKET_ERROR) {
    if (WSAEWOULDBLOCK == WSAGetLastError()) {
      fd_set fds;
      struct timeval timeout = { 2, 0 }; // 2 seconds, 0 micro-seconds
      FD_ZERO(&fds);
      FD_SET(the->connection, &fds);
      if (select(0, NULL, &fds, NULL, &timeout) == 0)
        goto bail;
      if (!FD_ISSET(the->connection, &fds))
        goto bail;
    }
    else
      goto bail;
  }
   flag = 0;
   ioctlsocket(the->connection, FIONBIO, &flag);
}
#else
{
  struct sockaddr_in address;
  int  flag;
  memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
  address.sin_addr.s_addr = inet_addr(name);
  if (address.sin_addr.s_addr == INADDR_NONE) {
    struct hostent *host = gethostbyname(name);
    if (!host)
      return;
    memcpy(&(address.sin_addr), host->h_addr, host->h_length);
  }
    address.sin_port = htons(port);
  the->connection = socket(AF_INET, SOCK_STREAM, 0);
  if (the->connection <= 0)
    goto bail;
  c_signal(SIGPIPE, SIG_IGN);
#if mxMacOSX
  {
    int set = 1;
    setsockopt(the->connection, SOL_SOCKET, SO_NOSIGPIPE, (void *)&set, sizeof(int));
  }
#endif
  flag = fcntl(the->connection, F_GETFL, 0);
  fcntl(the->connection, F_SETFL, flag | O_NONBLOCK);
  if (connect(the->connection, (struct sockaddr*)&address, sizeof(address)) < 0) {
       if (errno == EINPROGRESS) {
      fd_set fds;
      struct timeval timeout = { 2, 0 }; // 2 seconds, 0 micro-seconds
      int error = 0;
      unsigned int length = sizeof(error);
      FD_ZERO(&fds);
      FD_SET(the->connection, &fds);
      if (select(the->connection + 1, NULL, &fds, NULL, &timeout) == 0)
        goto bail;
      if (!FD_ISSET(the->connection, &fds))
        goto bail;
      if (getsockopt(the->connection, SOL_SOCKET, SO_ERROR, &error, &length) < 0)
        goto bail;
      if (error)
        goto bail;
    }
    else
      goto bail;
  }
  fcntl(the->connection, F_SETFL, flag);
  c_signal(SIGPIPE, SIG_DFL);
}
#endif
  return;
bail:
  fxDisconnect(the);
}

void fxDisconnect(txMachine* the)
{
#if mxWindows
  if (the->connection != INVALID_SOCKET) {
    closesocket(the->connection);
    the->connection = INVALID_SOCKET;
  }
  WSACleanup();
#else
  if (the->connection >= 0) {
    close(the->connection);
    the->connection = -1;
  }
#endif
}

txBoolean fxIsConnected(txMachine* the)
{
  return (the->connection != mxNoSocket) ? 1 : 0;
}

txBoolean fxIsReadable(txMachine* the)
{
  return 0;
}

void fxReceive(txMachine* the)
{
  int count;
  if (the->connection != mxNoSocket) {
#if mxWindows
    count = recv(the->connection, the->debugBuffer, sizeof(the->debugBuffer) - 1, 0);
    if (count < 0)
      fxDisconnect(the);
    else
      the->debugOffset = count;
#else
  again:
    count = read(the->connection, the->debugBuffer, sizeof(the->debugBuffer) - 1);
    if (count < 0) {
      if (errno == EINTR)
        goto again;
      else
        fxDisconnect(the);
    }
    else
      the->debugOffset = count;
#endif
  }
  the->debugBuffer[the->debugOffset] = 0;
}

void fxSend(txMachine* the, txBoolean more)
{
  if (the->connection != mxNoSocket) {
#if mxWindows
    if (send(the->connection, the->echoBuffer, the->echoOffset, 0) <= 0)
      fxDisconnect(the);
#else
  again:
    if (write(the->connection, the->echoBuffer, the->echoOffset) <= 0) {
      if (errno == EINTR)
        goto again;
      else
        fxDisconnect(the);
    }
#endif
  }
}

#endif /* mxDebug */
