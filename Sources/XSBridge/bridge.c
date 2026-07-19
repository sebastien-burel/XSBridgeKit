/*
 * bridge.c — the shim between Swift and the XS engine.
 *
 * The asynchronous bridge: a consumer's C host function calls xsServicePromise,
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
#include "xsSnapshot.h"
#include "xs.h"

#include "bridge.h"
#include "bridgeXS.h"
#include "bridgeInternal.h"

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
 *
 * The bridge/message/event structs and the shared settle machinery live in
 * bridgeInternal.h, so service.c (the machine↔machine peer) settles calls
 * through the same message list and worker-job event as the native peer here.
 * ------------------------------------------------------------------------- */

/* ---------------------------------------------------------------------------
 * Native host-function helper. A consumer's C host function marshals arg0 with
 * xsBridgeArgJSON, opens the async call with xsServicePromise (settle.c), then
 * hands (bridge, id, json) to its Swift @_cdecl counterpart; Swift settles later
 * via the native posters below (xsServiceResolve / xsServiceReject / xsServiceEmit).
 * ------------------------------------------------------------------------- */

/* JSON.stringify(xsArg(index)) as a malloc'd UTF-8 string — the marshalling
 * half of a host function (free() it after handing off to Swift). Uses
 * xsResult as scratch: call it BEFORE xsServicePromise. */
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
        if (bridge->moduleParams) {
          /* default(JSON.parse(params)) — a parse error rejects the run. */
          xsVar(1) = xsCall1(xsGet(xsGlobal, xsID("JSON")), xsID("parse"),
                             xsString(bridge->moduleParams));
          xsVar(1) = xsCallFunction1(xsVar(0), xsUndefined, xsVar(1));
        }
        else
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

void xsBridgeRunModule(void* machine, const char* path, const char* paramsJSON)
{
  xsMachine* the = (xsMachine*)machine;
  XSBridge* bridge = (XSBridge*)xsGetContext(the);
  bridge->moduleStatus = 0;
  free(bridge->moduleError);
  bridge->moduleError = NULL;
  free(bridge->moduleParams);
  bridge->moduleParams = paramsJSON ? strdup(paramsJSON) : NULL;

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

  ServiceMessage* p = bridge->messages;
  while (p) {
    ServiceMessage* n = p->next;
    free(p);
    p = n;
  }
  xsServiceFreePending(bridge);   /* server-side in-flight requests (service.c) */
  free(bridge->moduleError);
  free(bridge->moduleParams);
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
 * Snapshot — persist / restore the whole JS heap (fxWriteSnapshot /
 * fxReadSnapshot). The XS layer already guards the engine version and the
 * architecture (sizeof(txSlot)); what it can't know is our host-function set,
 * which the heap references by INDEX into snapshot->callbacks. So the host
 * registers a fixed, append-only table (name + callback), and each snapshot
 * carries its ordered name list — a restore accepts a table whose first N
 * names match (append is safe, reorder/removal is rejected). Only the JS heap
 * is serialized: the XSBridge context and the mac_xs platform are rebuilt on
 * restore (fxReadSnapshot calls fxCreateMachinePlatform and takes our context).
 *
 * Buffer layout: [ "XSBK" | u32 version | u32 nameCount | (u32 len, bytes)... ]
 * followed by the raw fxWriteSnapshot bytes.
 * ------------------------------------------------------------------------- */

#define XSB_SNAPSHOT_MAGIC "XSBK"
#define XSB_SNAPSHOT_VERSION 1u

/* Process-wide host table (host functions are frozen at boot). */
static const XSBridgeHostFn* gHostTable;
static int gHostCount;

void xsBridgeRegisterHostTable(const XSBridgeHostFn* fns, int count)
{
  gHostTable = fns;
  gHostCount = count;
}

/* Engine built-ins reachable from the heap that this XS checkout installs but
 * forgot to list in xsSnapshot.c's gxCallbacks table. fxProjectCallback falls
 * back to snapshot->callbacks, so we supplement them here (all mxExport). They
 * are build-constant, appended AFTER the host functions in the callback array;
 * both write and read build the same array, so their indices resolve. Revisit
 * on a Moddable bump: `comm -23 <installed> <gxCallbacks>` finds new gaps. */
static const txCallback gEngineSupplements[] = {
  fx_ArrayBuffer_fromString,
  fx_String_fromArrayBuffer,
};
#define XSB_SUPPLEMENT_COUNT ((int)(sizeof(gEngineSupplements) / sizeof(gEngineSupplements[0])))

/* Growable write buffer + cursor reader, both driving the snapshot I/O
 * callbacks (return 0 on success, non-zero errno on failure). */
typedef struct { char* data; size_t size; size_t cap; } XSBridgeWriteBuf;
typedef struct { const char* data; size_t size; size_t pos; } XSBridgeReadBuf;

static int xsBridgeBufWrite(void* stream, void* address, size_t size)
{
  XSBridgeWriteBuf* b = (XSBridgeWriteBuf*)stream;
  if (b->size + size > b->cap) {
    size_t ncap = b->cap ? b->cap * 2 : 64 * 1024;
    while (ncap < b->size + size) ncap *= 2;
    char* nd = (char*)realloc(b->data, ncap);
    if (!nd) return C_ENOMEM;
    b->data = nd;
    b->cap = ncap;
  }
  memcpy(b->data + b->size, address, size);
  b->size += size;
  return 0;
}

static int xsBridgeBufRead(void* stream, void* address, size_t size)
{
  XSBridgeReadBuf* r = (XSBridgeReadBuf*)stream;
  if (r->pos + size > r->size) return C_EINVAL;
  memcpy(address, r->data + r->pos, size);
  r->pos += size;
  return 0;
}

/* Fill a txSnapshot's version tag + callback table (shared by write/read).
 * `callbacks` must hold gHostCount + XSB_SUPPLEMENT_COUNT entries: the host
 * functions first (guarded by the name list), then the engine supplements. */
static void xsBridgeFillSnapshot(txSnapshot* snap, txCallback* callbacks)
{
  static char signature[] = "XSBridge " __DATE__;
  int n = 0;
  for (int i = 0; i < gHostCount; i++)
    callbacks[n++] = gHostTable[i].callback;
  for (int i = 0; i < XSB_SUPPLEMENT_COUNT; i++)
    callbacks[n++] = gEngineSupplements[i];
  memset(snap, 0, sizeof(txSnapshot));
  snap->signature = (txString)signature;
  snap->signatureLength = sizeof(signature) - 1;
  snap->callbacks = callbacks;
  snap->callbacksLength = n;
}

int xsBridgeWriteSnapshot(void* machine, char** out, size_t* outLen)
{
  *out = NULL;
  *outLen = 0;
  if (gHostCount <= 0)
    return -1;

  txCallback* callbacks = (txCallback*)calloc((size_t)(gHostCount + XSB_SUPPLEMENT_COUNT), sizeof(txCallback));
  XSBridgeWriteBuf buf = { NULL, 0, 0 };
  txSnapshot snap;
  xsBridgeFillSnapshot(&snap, callbacks);
  snap.stream = &buf;
  snap.write = xsBridgeBufWrite;

  /* Our header: magic + version + ordered host-function names. */
  uint32_t u = XSB_SNAPSHOT_VERSION;
  int err = xsBridgeBufWrite(&buf, XSB_SNAPSHOT_MAGIC, 4);
  if (!err) err = xsBridgeBufWrite(&buf, &u, sizeof(u));
  u = (uint32_t)gHostCount;
  if (!err) err = xsBridgeBufWrite(&buf, &u, sizeof(u));
  for (int i = 0; i < gHostCount && !err; i++) {
    uint32_t len = (uint32_t)strlen(gHostTable[i].name);
    err = xsBridgeBufWrite(&buf, &len, sizeof(len));
    if (!err) err = xsBridgeBufWrite(&buf, (void*)gHostTable[i].name, len);
  }

  /* The engine appends the heap. NB: fxWriteSnapshot returns 1 on success,
   * 0 on failure (inverted); the real error code is snap.error. */
  if (!err) {
    fxWriteSnapshot((xsMachine*)machine, &snap);
    err = snap.error;
  }

  free(callbacks);
  if (err) {
    free(buf.data);
    return err;
  }
  *out = buf.data;
  *outLen = buf.size;
  return 0;
}

/* Read a u32 from the reader, or return the error. */
static int xsBridgeReadU32(XSBridgeReadBuf* r, uint32_t* v)
{
  return xsBridgeBufRead(r, v, sizeof(*v));
}

void* xsBridgeReadSnapshot(const char* bytes, size_t len)
{
  if (gHostCount <= 0)
    return NULL;

  XSBridgeReadBuf r = { bytes, len, 0 };
  char magic[4];
  uint32_t version = 0, nameCount = 0;
  if (xsBridgeBufRead(&r, magic, 4) || memcmp(magic, XSB_SNAPSHOT_MAGIC, 4)) {
    fprintf(stderr, "snapshot: bad magic\n");
    return NULL;
  }
  if (xsBridgeReadU32(&r, &version) || version != XSB_SNAPSHOT_VERSION) {
    fprintf(stderr, "snapshot: unsupported version\n");
    return NULL;
  }
  /* Prefix check: the snapshot's names must equal the first nameCount entries
   * of the registered table (a longer table = appended functions, allowed). */
  if (xsBridgeReadU32(&r, &nameCount) || (int)nameCount > gHostCount) {
    fprintf(stderr, "snapshot: host table shorter than snapshot\n");
    return NULL;
  }
  for (uint32_t i = 0; i < nameCount; i++) {
    uint32_t nlen = 0;
    char name[256];
    if (xsBridgeReadU32(&r, &nlen) || nlen >= sizeof(name)
        || xsBridgeBufRead(&r, name, nlen)) {
      fprintf(stderr, "snapshot: truncated host name\n");
      return NULL;
    }
    name[nlen] = 0;
    if (strcmp(name, gHostTable[i].name)) {
      fprintf(stderr, "snapshot: host table mismatch at %u (snapshot=%s, table=%s)\n",
              i, name, gHostTable[i].name);
      return NULL;
    }
  }

  txCallback* callbacks = (txCallback*)calloc((size_t)(gHostCount + XSB_SUPPLEMENT_COUNT), sizeof(txCallback));
  txSnapshot snap;
  xsBridgeFillSnapshot(&snap, callbacks);
  snap.stream = &r;             /* cursor now positioned past our header */
  snap.read = xsBridgeBufRead;

  XSBridge* bridge = (XSBridge*)calloc(1, sizeof(XSBridge));
  xsMachine* machine = fxReadSnapshot(&snap, "XSBridge", bridge);
  free(callbacks);
  if (!machine || snap.error) {
    fprintf(stderr, "snapshot: read failed (%d)\n", snap.error);
    free(bridge);
    return NULL;
  }
  bridge->machine = machine;
  return machine;
}

/* ---------------------------------------------------------------------------
 * Called from Swift background threads.
 * ------------------------------------------------------------------------- */

/* Build a worker job and hand it to mac_xs.c's queue, which serializes the
 * enqueue under its worker mutex, signals the XS thread's run loop, and later
 * invokes `cb` there. Called from Swift background threads. The event carries a
 * native (JSON) payload; `cb` is one of the ServiceEvent* settle callbacks. */
static void xsBridgeNativePost(XSBridge* bridge, uint32_t id, txWorkerCallback cb,
                               const char* json)
{
    ServiceEvent* j = (ServiceEvent*)calloc(1, sizeof(ServiceEvent));
    j->job.callback = cb;
    j->payload = XSB_PAYLOAD_JSON;
    j->id = id;
    j->json = strdup(json ? json : "null");
    fxQueueWorkerJob(bridge->machine, j);
}

void xsServiceEmit(void* bridge, uint32_t id, const char* json)
{
    xsBridgeNativePost((XSBridge*)bridge, id, ServiceEventToken, json);
}

void xsServiceResolve(void* bridge, uint32_t id, const char* json)
{
    xsBridgeNativePost((XSBridge*)bridge, id, ServiceEventResolve, json);
}

void xsServiceReject(void* bridge, uint32_t id, const char* json)
{
    xsBridgeNativePost((XSBridge*)bridge, id, ServiceEventReject, json);
}


/* ---------------------------------------------------------------------------
 * Introspection for the harness.
 * ------------------------------------------------------------------------- */

int xsBridgePendingCount(void* machine)
{
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);
    int n = 0;
    for (ServiceMessage* p = bridge->messages; p; p = p->next)
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
