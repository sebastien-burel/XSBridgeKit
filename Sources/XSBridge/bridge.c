/*
 * bridge.c — the shim between Swift and the XS engine.
 *
 * The asynchronous bridge: a JS Promise is created on the JS side; __nativeCall
 * roots its resolve/reject (fxRemember), dispatches the request to Swift, and
 * Swift settles it later from a background queue by posting a worker job
 * (fxQueueWorkerJob, from the macOS platform port mac_xs.c). The job callback,
 * run on the XS thread, resolves/rejects, fxForgets, and drains promise jobs to
 * resume the awaiting JS continuation. mac_xs.c owns the run-loop integration
 * (worker-job queue + promise source); this file holds the host functions, the
 * pending-call bookkeeping, and the settlement logic.
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

/* ---------------------------------------------------------------------------
 * Platform layer. The macOS port (mac_xs.c) now provides the run-loop
 * integration — fxCreateMachinePlatform / fxDeleteMachinePlatform, the
 * cross-thread worker-job queue (fxQueueWorkerJob) and the promise run-loop
 * source — and module loading (mxUseDefaultFindModule / mxUseDefaultLoadModule).
 * The host program must still supply fxAbort, which mac_xs.c leaves out (it
 * normally comes from xst.c, which we exclude). The shared-timer functions are
 * not needed: mac_xs.h defines mxUseGCCAtomics, which compiles out the
 * shared-timer paths in xsAtomics.c.
 * ------------------------------------------------------------------------- */

void fxAbort(txMachine* the, int status)
{
    if (XS_DEBUGGER_EXIT == status)
        c_exit(1);
    if (the->exitStatus) /* xsEndHost calls fxAbort! */
        return;
    the->exitStatus = status;
    fxExitToHost(the);
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

/* A unit of work handed back from a Swift background thread to the XS thread via
 * mac_xs.c's worker-job queue. The txWorkerJob header MUST be first: the queue
 * links and c_free's the struct by that header. Carries a streamed token
 * (XSB_TOKEN, keeps the call open) or the final settlement (XSB_RESOLVE/REJECT). */
typedef struct XSBJob {
    txWorkerJob job;    /* { next, callback } — must be first */
    uint32_t id;
    int type;
    char* json;         /* token delta / result value as JSON (owned) */
} XSBJob;

typedef struct XSBridge {
    xsMachine* machine;
    void* swiftContext;     /* opaque XSEngine pointer, for sync host.add */
    uint32_t nextId;
    XSPending* pending;    /* XS-thread only */

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

/* Module loader hooks (Swift @_cdecl). find resolves a specifier (relative to
 * the importer) to a canonical id; load returns that id's source. Both return a
 * malloc'd UTF-8 string the C side frees, or NULL. */
extern char* xsb_dispatch_find_module(void* bridge, const char* specifier,
                                      const char* importer);
extern char* xsb_dispatch_load_module(void* bridge, const char* id);

static void xsb_job_perform(void* machine, void* job);

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
 * Module loader. mac_xs.h turns the XS default find/load module OFF, so we
 * supply both. Policy lives in Swift: fxFindModule asks the host to resolve a
 * specifier (relative to the importing module) to a canonical id; fxLoadModule
 * asks for that id's source, which we parse in memory as a Module (no
 * mxProgramFlag — so `import`/`export` are legal) and resolve. A NULL from
 * either surfaces to JS as a module-not-found rejection.
 * ------------------------------------------------------------------------- */

txID fxFindModule(txMachine* the, txSlot* realm, txID moduleID, txSlot* slot)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);
    char specifier[C_PATH_MAX];
    fxToStringBuffer(the, slot, specifier, sizeof(specifier));
    /* moduleID is the importer's id (XS_NO_ID for a top-level / dynamic import). */
    const char* importer = (moduleID != XS_NO_ID) ? fxGetKeyName(the, moduleID) : NULL;

    char* resolved = xsb_dispatch_find_module(bridge, specifier, importer);
    if (!resolved)
        return XS_NO_ID;
    txID id = fxNewNameC(the, resolved);
    free(resolved);
    return id;
}

void fxLoadModule(txMachine* the, txSlot* module, txID moduleID)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);
    const char* id = fxGetKeyName(the, moduleID);

    char* source = xsb_dispatch_load_module(bridge, id);
    if (!source)
        return;   /* module stays unresolved -> JS "module not found" */

    txUnsigned flags = 0;   /* Module goal; a Script would set mxProgramFlag. */
    size_t len = c_strlen(id);
    if (len >= 5 && c_strcmp(id + (len - 5), ".json") == 0)
        flags |= mxJSONModuleFlag;

    /* fxParseScript catches its own parse jump and returns NULL on a syntax
     * error (no longjmp), so freeing source right after is always safe. */
    txStringCStream stream;
    stream.buffer = source;
    stream.offset = 0;
    stream.size = (txSize)c_strlen(source);
    txScript* script = fxParseScript(the, &stream, fxStringCGetter, flags);
    free(source);
    if (script)
        fxResolveModule(the, module, moduleID, script, C_NULL, C_NULL);
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

/* Drain the microtask (promise jobs) queue to quiescence, within a host frame.
 * mac_xs.c's fxQueuePromiseJobs signals a run-loop source rather than setting a
 * flag, so we drain explicitly here to guarantee that once a call's pending
 * record is gone, its `await` continuation has already run (the harness treats
 * pending_count == 0 as "fully settled"). Must be called inside xsBeginHost. */
static void xsb_drain_promises(txMachine* the)
{
    xsTry {
        while (mxPendingJobs.value.reference->next)
            fxRunPromiseJobs(the);
    }
    xsCatch {
    }
}

/* Worker-job callback: mac_xs.c invokes it on the XS thread (unframed) for each
 * job posted via fxQueueWorkerJob. Applies one streamed token or one final
 * settlement, then drains promise jobs. */
static void xsb_job_perform(void* machine, void* job_)
{
    XSBJob* j = (XSBJob*)job_;
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(2);
        if (j->type == XSB_TOKEN) {
            /* Reverse channel: invoke onToken(delta), keep the call open. */
            XSPending* rec = xsb_find_pending(bridge, j->id);
            if (rec && rec->hasOnToken) {
                xsTry {
                    xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
                    xsVar(1) = xsCall1(xsVar(0), xsID("parse"), xsString(j->json));
                    xsCallFunction1(xsAccess(rec->onToken), xsUndefined, xsVar(1));
                }
                xsCatch {
                }
            }
        } else {
            /* Final settlement: resolve/reject, then forget all roots. */
            XSPending* rec = xsb_unlink_pending(bridge, j->id);
            if (rec) {
                xsTry {
                    xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
                    xsVar(1) = xsCall1(xsVar(0), xsID("parse"), xsString(j->json));
                    if (j->type == XSB_RESOLVE)
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
        xsb_drain_promises(the);
    }
    xsEndHost((xsMachine*)machine);

    free(j->json);   /* mac_xs.c c_free's the job struct itself */
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
    /* mac_xs.c's fxCreateMachinePlatform — run inside xsCreateMachine, on this
     * thread — has already attached the worker-job and promise run-loop sources
     * to the current run loop (this dedicated XS thread's loop). */
    xsb_install_host(machine);
    return machine;
}

void xsb_delete_machine(void* machine)
{
    if (!machine)
        return;
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    /* xsDeleteMachine runs mac_xs.c's fxDeleteMachinePlatform, which tears down
     * the worker/promise run-loop sources, the worker mutex, and frees any
     * worker jobs still queued. */
    xsDeleteMachine((xsMachine*)machine);

    XSPending* p = bridge->pending;
    while (p) {
        XSPending* n = p->next;
        free(p);
        p = n;
    }
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

/* Build a worker job and hand it to mac_xs.c's queue, which serializes the
 * enqueue under its worker mutex, signals the XS thread's run loop, and later
 * invokes xsb_job_perform there. Called from Swift background threads. */
static void xsb_post(XSBridge* bridge, uint32_t id, int type, const char* json)
{
    XSBJob* j = (XSBJob*)calloc(1, sizeof(XSBJob));
    j->job.callback = xsb_job_perform;
    j->id = id;
    j->type = type;
    j->json = strdup(json ? json : "null");
    fxQueueWorkerJob(bridge->machine, j);
}

void xsb_emit_token(void* bridge, uint32_t id, const char* json)
{
    xsb_post((XSBridge*)bridge, id, XSB_TOKEN, json);
}

void xsb_complete(void* bridge, uint32_t id, int success, const char* json)
{
    xsb_post((XSBridge*)bridge, id, success ? XSB_RESOLVE : XSB_REJECT, json);
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
         * a pure (host-call-free) agent never makes. */
        xsb_drain_promises(the);
    }
    xsEndHost((xsMachine*)machine);

    return ok;
}
