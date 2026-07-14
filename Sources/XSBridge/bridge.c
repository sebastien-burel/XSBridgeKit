/*
 * bridge.c — the shim between Swift and the XS engine.
 *
 * The asynchronous bridge: a consumer's C host function calls xsBridgePromise,
 * which creates the JS Promise here (fxNewPromiseCapability), roots its
 * resolve/reject (fxRemember) in a message record, and returns an id. The host
 * function hands (bridge, id) to Swift; Swift settles later from a background
 * queue by posting a worker job (fxQueueWorkerJob, from the macOS platform
 * port mac_xs.c). The job callback, run on the XS thread, resolves/rejects,
 * fxForgets, and drains promise jobs to resume the awaiting JS continuation.
 * mac_xs.c owns the run-loop integration (worker-job queue + promise source);
 * this file holds the message bookkeeping and the settlement logic.
 *
 * Invariants: XS is single-threaded (all machine access on the run-loop thread);
 * no xsSlot crosses into Swift (only opaque ids + UTF-8 JSON); every Swift->XS
 * entry is framed by xsBeginHost/xsEndHost with xsTry/xsCatch.
 */
#include "xsAll.h"
#include "xsScript.h"
#include "xs.h"

#include "bridge.h"
#include "bridgeXS.h"

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
typedef struct XSMessage {
    uint32_t id;
    txSlot resolve;
    txSlot reject;
    txSlot onToken;
    int hasOnToken;
    struct XSMessage* next;
} XSMessage;

/* A unit of work handed back from a Swift background thread to the XS thread via
 * mac_xs.c's worker-job queue. The txWorkerJob header MUST be first: the queue
 * links and c_free's the struct by that header. Carries a streamed token
 * (XSB_TOKEN, keeps the call open) or the final settlement (XSB_RESOLVE/REJECT). */
typedef struct XSEvent {
    txWorkerJob job;    /* { next, callback } — must be first */
    uint32_t id;
    int type;
    char* json;         /* token delta / result value as JSON (owned) */
} XSEvent;

typedef struct XSBridge {
    xsMachine* machine;
    void* swiftContext;     /* opaque Swift pointer (xsBridgeSet/GetContext) */
    uint32_t nextId;
    XSMessage* messages;   /* in-flight calls, XS-thread only */

    uint32_t rememberCount; /* leak accounting */
    uint32_t forgetCount;

    int moduleStatus;       /* xsBridgeRunModule: 0 pending, 1 fulfilled, 2 rejected */
    char* moduleError;      /* rejection message (malloc'd), XS-thread only */
} XSBridge;

static void xsBridgeEventPerform(void* machine, void* job);
static void xsBridgeDrainPromises(txMachine* the);

/* ---------------------------------------------------------------------------
 * Native-call entry — the one helper consumer C host functions need. The C
 * layer knows nothing about specific host capabilities (echo, tools, chat, …):
 * a consumer target installs its own host functions (xsNewHostFunction), each
 * of which calls xsBridgePromise then hands (bridge, id, plain params) to its
 * Swift @_cdecl counterpart.
 * ------------------------------------------------------------------------- */

/* Create the Promise for an in-flight native call: build a promise capability,
 * copy resolve/reject (+ optional onToken) into stable C memory and root them
 * BEFORE any further allocation (the stack temporaries keep them alive up to
 * that point), link the message record, set xsResult to the promise and return
 * the id. Must run inside a host frame (a C host function). */
uint32_t xsBridgePromise(xsMachine* the, xsSlot* onToken)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);
    XSMessage* rec = (XSMessage*)calloc(1, sizeof(XSMessage));
    txSlot* resolveFunction;
    txSlot* rejectFunction;

    rec->id = ++bridge->nextId;

    mxTemporary(resolveFunction);
    mxTemporary(rejectFunction);
    mxPush(mxPromiseConstructor);
    fxNewPromiseCapability(the, resolveFunction, rejectFunction);
    mxPullSlot(mxResult);
    rec->resolve = *resolveFunction;
    rec->reject = *rejectFunction;
    fxRemember(the, &rec->resolve);
    fxRemember(the, &rec->reject);
    bridge->rememberCount += 2;
    mxPop();
    mxPop();

    if (onToken) {
        rec->onToken = *onToken;
        fxRemember(the, &rec->onToken);
        rec->hasOnToken = 1;
        bridge->rememberCount += 1;
    }
    rec->next = bridge->messages;
    bridge->messages = rec;
    return rec->id;
}

/* JSON.stringify(xsArg(index)) as a malloc'd UTF-8 string — the marshalling
 * half of a host function (free() it after handing off to Swift). Uses
 * xsResult as scratch: call it BEFORE xsBridgePromise. */
char* xsBridgeArgJSON(xsMachine* the, int index)
{
  xsResult = xsCall1(xsGet(xsGlobal, xsID("JSON")), xsID("stringify"), xsArg(index));
  return strdup(xsToString(xsResult));
}

/* ---------------------------------------------------------------------------
 * Module loader — filesystem, the platform-port way (macos_xs.c / xst).
 * mac_xs.h turns the XS default find/load module OFF, so we supply both.
 * A module id is the realpath of its file. fxFindModule resolves `./`/`../`
 * against the importing module's path (a relative specifier is invalid at the
 * top level), recognizes `.js`/`.mjs` extensions (no extension guessing), and
 * probes the file with realpath. fxLoadModule parses the file from disk as a
 * Module (no mxProgramFlag). A miss surfaces to JS as module-not-found.
 * ------------------------------------------------------------------------- */

txID fxFindModule(txMachine* the, txSlot* realm, txID moduleID, txSlot* slot)
{
    char name[C_PATH_MAX];
    char buffer[C_PATH_MAX];
    char real[C_PATH_MAX];
    char extension[5] = "";
    txInteger dot = 0;
    txString slash;
    txString path;
    fxToStringBuffer(the, slot, name, sizeof(name));
    if (name[0] == '.') {
        if (name[1] == '/')
            dot = 1;
        else if ((name[1] == '.') && (name[2] == '/'))
            dot = 2;
    }
    slash = c_strrchr(name, mxSeparator);
    if (!slash)
        slash = name;
    slash = c_strrchr(slash, '.');
    if (slash && (!c_strcmp(slash, ".js") || !c_strcmp(slash, ".mjs") || !c_strcmp(slash, ".xsb"))) {
        c_strcpy(extension, slash);
        *slash = 0;
    }
    if (dot) {
        if (moduleID == XS_NO_ID)
            return XS_NO_ID;
        /* Prepend a separator so strrchr always finds one, then replace the
         * importer's last component(s) with the relative specifier. */
        buffer[0] = mxSeparator;
        path = buffer + 1;
        c_strcpy(path, fxGetKeyName(the, moduleID));
        slash = c_strrchr(buffer, mxSeparator);
        if (!slash)
            return XS_NO_ID;
        if (dot == 2) {
            *slash = 0;
            slash = c_strrchr(buffer, mxSeparator);
            if (!slash)
                return XS_NO_ID;
        }
        *slash = 0;
        c_strcat(buffer, name + dot);
    }
    else
        path = name;
    c_strcat(path, extension);
    if (c_realpath(path, real))
        return fxNewNameC(the, real);
    return XS_NO_ID;
}

/* Parse a script/module file with the XS parser (macos_xs.c pattern), source
 * map indirection included. Returns NULL on any error (file missing, syntax). */
static txScript* xsBridgeLoadScript(txMachine* the, txString path, txUnsigned flags)
{
    txParser _parser;
    txParser* parser = &_parser;
    txParserJump jump;
    FILE* file = NULL;
    txString name = NULL;
    char map[C_PATH_MAX];
    txScript* script = NULL;
    fxInitializeParser(parser, the, the->parserBufferSize, the->parserTableModulo);
    parser->firstJump = &jump;
    file = fopen(path, "r");
    if (c_setjmp(jump.jmp_buf) == 0) {
        mxParserThrowElse(file);
        parser->path = fxNewParserSymbol(parser, path);
        fxParserTree(parser, file, (txGetter)fgetc, flags, &name);
        fclose(file);
        file = NULL;
        if (name) {
            txString slash = c_strrchr(path, mxSeparator);
            if (slash) *slash = 0;
            c_strcat(path, name);
            mxParserThrowElse(c_realpath(path, map));
            parser->path = fxNewParserSymbol(parser, map);
            file = fopen(map, "r");
            mxParserThrowElse(file);
            fxParserSourceMap(parser, file, (txGetter)fgetc, flags, &name);
            fclose(file);
            file = NULL;
            if (parser->errorCount == 0) {
                if (slash) *slash = 0;
                c_strcat(path, name);
                mxParserThrowElse(c_realpath(path, map));
                parser->path = fxNewParserSymbol(parser, map);
            }
        }
        fxParserHoist(parser);
        fxParserBind(parser);
        script = fxParserCode(parser);
    }
    if (file)
        fclose(file);
    fxTerminateParser(parser);
    return script;
}

/* ---------------------------------------------------------------------------
 * Compiled modules (.xsb, produced by xsc) — reader modeled on the linker's
 * fxNewLinkerScript (xslBase.c): big-endian atoms XS_B > VERS > SYMB > CODE
 * [> HOST]. The engine does the rest: fxRunScript remaps the symbol table to
 * machine ids (fxRemapScript) and frees the buffers (fxDeleteScript) — so the
 * script struct and each buffer must be its own malloc'd block.
 * ------------------------------------------------------------------------- */

static int xsBridgeReadAtom(FILE* file, txU4* size, txU4* type)
{
    txU1 b[8];
    if (fread(b, 8, 1, file) != 1)
        return 0;
    *size = ((txU4)b[0] << 24) | ((txU4)b[1] << 16) | ((txU4)b[2] << 8) | b[3];
    *type = ((txU4)b[4] << 24) | ((txU4)b[5] << 16) | ((txU4)b[6] << 8) | b[7];
    return 1;
}

static txScript* xsBridgeReadBinary(txString path)
{
    FILE* file = fopen(path, "rb");
    txScript* script = NULL;
    txU4 size, type;
    const char* reason;

    reason = "cannot open";
    if (!file)
        goto bail;
    script = (txScript*)calloc(1, sizeof(txScript));

    reason = "bad signature";
    if (!xsBridgeReadAtom(file, &size, &type) || type != XS_ATOM_BINARY)
        goto bail;
    reason = "bad version atom";
    if (!xsBridgeReadAtom(file, &size, &type) || type != XS_ATOM_VERSION
        || size != 8 + sizeof(script->version)
        || fread(script->version, sizeof(script->version), 1, file) != 1)
        goto bail;
    reason = "XS version mismatch";
    if ((script->version[0] != XS_MAJOR_VERSION)
        || (script->version[1] != XS_MINOR_VERSION))
        goto bail;
    reason = "compiled with errors";
    if (script->version[3] == 1)
        goto bail;
    reason = "host functions not supported";
    if (script->version[3] == -1)
        goto bail;

    reason = "bad symbols atom";
    if (!xsBridgeReadAtom(file, &size, &type) || type != XS_ATOM_SYMBOLS || size <= 8)
        goto bail;
    script->symbolsSize = (txSize)(size - 8);
    script->symbolsBuffer = (txByte*)malloc(script->symbolsSize);
    if (fread(script->symbolsBuffer, script->symbolsSize, 1, file) != 1)
        goto bail;

    reason = "bad code atom";
    if (!xsBridgeReadAtom(file, &size, &type) || type != XS_ATOM_CODE || size <= 8)
        goto bail;
    script->codeSize = (txSize)(size - 8);
    script->codeBuffer = (txByte*)malloc(script->codeSize);
    if (fread(script->codeBuffer, script->codeSize, 1, file) != 1)
        goto bail;

    fclose(file);
    return script;

bail:
    fprintf(stderr, "xsb: %s (%s)\n", reason, path);
    if (file)
        fclose(file);
    fxDeleteScript(script);
    return NULL;
}

void fxLoadModule(txMachine* the, txSlot* module, txID moduleID)
{
    txString path = fxGetKeyName(the, moduleID);
    txSize length = mxStringLength(path);
    txScript* script;
    if ((length > 4) && !c_strcmp(path + length - 4, ".xsb"))
        script = xsBridgeReadBinary(path);
    else {
#ifdef mxDebug
        txUnsigned flags = mxDebugFlag;
#else
        txUnsigned flags = 0;
#endif
        script = xsBridgeLoadScript(the, path, flags);
    }
    if (script)
        fxResolveModule(the, module, moduleID, script, C_NULL, C_NULL);
}

/* ---------------------------------------------------------------------------
 * Run a module file: dynamic-import the path, attach then(fulfilled, rejected)
 * host functions that record the outcome in the bridge, and drain promise jobs
 * so a module with no async work is settled on return. A module still awaiting
 * host calls settles later on the run loop; poll xsBridgeModuleStatus once idle.
 *
 * Entry convention: if the namespace has a callable `default` export, it is
 * invoked on EVERY run — the module body evaluates only once (module cache),
 * the default is the repeatable action. The run settles when the default's
 * result settles (Promise.resolve-normalized), and a throw/rejection from the
 * default rejects the run.
 * ------------------------------------------------------------------------- */

static void xsBridgeModuleRejected(xsMachine* the);

/* The default's result settled: the run is fulfilled. */
static void xsBridgeDefaultDone(xsMachine* the)
{
  XSBridge* bridge = (XSBridge*)xsGetContext(the);
  bridge->moduleStatus = 1;
}

static void xsBridgeModuleFulfilled(xsMachine* the)
{
  XSBridge* bridge = (XSBridge*)xsGetContext(the);
  int chained = 0;
  xsVars(2);
  xsTry {
    if (xsTypeOf(xsArg(0)) == xsReferenceType) {
      xsVar(0) = xsGet(xsArg(0), xsID("default"));
      if (fxIsCallable(the, &xsVar(0))) {
        xsVar(1) = xsCallFunction0(xsVar(0), xsUndefined);
        /* Settle the run with the default's result, sync or async alike. */
        xsVar(1) = xsCall1(xsGet(xsGlobal, xsID("Promise")), xsID("resolve"), xsVar(1));
        xsVar(1) = xsCall2(xsVar(1), xsID("then"),
                           xsNewHostFunction(xsBridgeDefaultDone, 1),
                           xsNewHostFunction(xsBridgeModuleRejected, 1));
        chained = 1;
      }
    }
    if (!chained)
      bridge->moduleStatus = 1;
  }
  xsCatch {
    /* The default threw synchronously. */
    bridge->moduleStatus = 2;
    free(bridge->moduleError);
    bridge->moduleError = strdup(xsToString(xsException));
  }
}

static void xsBridgeModuleRejected(xsMachine* the)
{
  XSBridge* bridge = (XSBridge*)xsGetContext(the);
  bridge->moduleStatus = 2;
  free(bridge->moduleError);
  bridge->moduleError = NULL;
  xsTry {
    bridge->moduleError = strdup(xsToString(xsArg(0)));
  }
  xsCatch {
    bridge->moduleError = strdup("module rejected");
  }
}

void xsBridgeRunModule(void* machine, const char* path)
{
  xsMachine* the = (xsMachine*)machine;
  XSBridge* bridge = (XSBridge*)xsGetContext(the);
  bridge->moduleStatus = 0;
  free(bridge->moduleError);
  bridge->moduleError = NULL;

  xsBeginHost(the);
  {
    xsTry {
      txSlot* realm = mxProgram.value.reference->next->value.module.realm;
      mxPushStringC((txString)path);
      mxPushUndefined();
      fxRunImport(the, realm, C_NULL);
      mxDub();
      fxGetID(the, mxID(_then));
      mxCall();
      fxNewHostFunction(the, xsBridgeModuleFulfilled, 1, XS_NO_ID, XS_NO_ID);
      fxNewHostFunction(the, xsBridgeModuleRejected, 1, XS_NO_ID, XS_NO_ID);
      mxRunCount(2);
      mxPop();
    }
    xsCatch {
      bridge->moduleStatus = 2;
      free(bridge->moduleError);
      bridge->moduleError = strdup(xsToString(xsException));
    }
    xsBridgeDrainPromises(the);
  }
  xsEndHost(the);
}

int xsBridgeModuleStatus(void* machine, char** out_err)
{
  XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
  if (out_err) *out_err = (bridge->moduleStatus == 2 && bridge->moduleError) ? strdup(bridge->moduleError) : NULL;
  return bridge->moduleStatus;
}

/* ---------------------------------------------------------------------------
 * Run-loop perform: settle promises on the XS thread.
 * ------------------------------------------------------------------------- */

static XSMessage* xsBridgeUnlinkMessage(XSBridge* bridge, uint32_t id)
{
    XSMessage** addr = &bridge->messages;
    XSMessage* p;
    while ((p = *addr)) {
        if (p->id == id) {
            *addr = p->next;
            return p;
        }
        addr = &p->next;
    }
    return NULL;
}

static XSMessage* xsBridgeFindMessage(XSBridge* bridge, uint32_t id)
{
    for (XSMessage* p = bridge->messages; p; p = p->next)
        if (p->id == id)
            return p;
    return NULL;
}

/* Drain the microtask (promise jobs) queue to quiescence, within a host frame.
 * mac_xs.c's fxQueuePromiseJobs signals a run-loop source rather than setting a
 * flag, so we drain explicitly here to guarantee that once a call's message
 * record is gone, its `await` continuation has already run (the harness treats
 * pendingCount == 0 as "fully settled"). Must be called inside xsBeginHost. */
static void xsBridgeDrainPromises(txMachine* the)
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
static void xsBridgeEventPerform(void* machine, void* job_)
{
    XSEvent* j = (XSEvent*)job_;
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(2);
        if (j->type == XSB_TOKEN) {
            /* Reverse channel: invoke onToken(delta), keep the call open. */
            XSMessage* rec = xsBridgeFindMessage(bridge, j->id);
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
            XSMessage* rec = xsBridgeUnlinkMessage(bridge, j->id);
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
        xsBridgeDrainPromises(the);
    }
    xsEndHost((xsMachine*)machine);

    free(j->json);   /* mac_xs.c c_free's the job struct itself */
}

/* ---------------------------------------------------------------------------
 * Machine lifecycle.
 * ------------------------------------------------------------------------- */

void* xsBridgeCreateMachine(const XSBridgeCreation* c)
{
  xsCreation creation = {
    c->initialChunkSize,
    c->incrementalChunkSize,
    c->initialHeapCount,
    c->incrementalHeapCount,
    c->stackCount,
    c->initialKeyCount,
    c->incrementalKeyCount,
    c->nameModulo,
    c->symbolModulo,
    c->parserBufferSize,
    c->parserTableModulo,
    /* staticSize, nativeStackSize: 0 (unused by this build) */
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
  * to the current run loop (this dedicated XS thread's loop). The bridge
  * installs no host functions — even print is consumer-supplied. */
  return machine;
}

void xsBridgeDeleteMachine(void* machine)
{
  if (!machine)
    return;
  XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);

  /* xsDeleteMachine runs mac_xs.c's fxDeleteMachinePlatform, which tears down
  * the worker/promise run-loop sources, the worker mutex, and frees any
  * worker jobs still queued. */
  xsDeleteMachine((xsMachine*)machine);

  XSMessage* p = bridge->messages;
  while (p) {
    XSMessage* n = p->next;
    free(p);
    p = n;
  }
  free(bridge->moduleError);
  free(bridge);
}

void xsBridgeSetContext(void* machine, void* context)
{
  XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
  bridge->swiftContext = context;
}

/* The opaque Swift context, recovered from the bridge pointer that the async
 * dispatch callbacks receive (so they can find the owning engine/HostBridge). */
void* xsBridgeGetContext(void* bridge)
{
  return ((XSBridge*)bridge)->swiftContext;
}

/* ---------------------------------------------------------------------------
 * Called from Swift background threads.
 * ------------------------------------------------------------------------- */

/* Build a worker job and hand it to mac_xs.c's queue, which serializes the
 * enqueue under its worker mutex, signals the XS thread's run loop, and later
 * invokes xsBridgeEventPerform there. Called from Swift background threads. */
static void xsBridgeEventPost(XSBridge* bridge, uint32_t id, int type, const char* json)
{
    XSEvent* j = (XSEvent*)calloc(1, sizeof(XSEvent));
    j->job.callback = xsBridgeEventPerform;
    j->id = id;
    j->type = type;
    j->json = strdup(json ? json : "null");
    fxQueueWorkerJob(bridge->machine, j);
}

void xsBridgeEmitToken(void* bridge, uint32_t id, const char* json)
{
    xsBridgeEventPost((XSBridge*)bridge, id, XSB_TOKEN, json);
}

void xsBridgeComplete(void* bridge, uint32_t id, int success, const char* json)
{
    xsBridgeEventPost((XSBridge*)bridge, id, success ? XSB_RESOLVE : XSB_REJECT, json);
}

/* ---------------------------------------------------------------------------
 * Introspection for the harness.
 * ------------------------------------------------------------------------- */

int xsBridgePendingCount(void* machine)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    int n = 0;
    for (XSMessage* p = bridge->messages; p; p = p->next)
        n++;
    return n;
}

/* Force a full garbage collection on the XS thread. Used by the stress test to
 * prove that in-flight resolve/reject/onToken roots survive collection. */
void xsBridgeCollectGarbage(void* machine)
{
    xsBeginHost((xsMachine*)machine);
    {
        xsCollectGarbage();
    }
    xsEndHost((xsMachine*)machine);
}

void xsBridgeDebugCounts(void* machine, uint32_t* remembered, uint32_t* forgotten)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    if (remembered) *remembered = bridge->rememberCount;
    if (forgotten) *forgotten = bridge->forgetCount;
}

/* ---------------------------------------------------------------------------
 * Eval.
 * ------------------------------------------------------------------------- */

void xsBridgeFree(char* s)
{
    free(s);
}

int xsBridgeEval(void* machine, const char* src, char** out_json, char** out_err)
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
        xsBridgeDrainPromises(the);
    }
    xsEndHost((xsMachine*)machine);

    return ok;
}
