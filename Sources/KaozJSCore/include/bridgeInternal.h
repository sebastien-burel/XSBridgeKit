/*
 * bridgeInternal.h — shared internals of the XSBridge C target.
 *
 * Split point between bridge.c (machine lifecycle + native peer settlement) and
 * service.c (machine↔machine service round-trip). Both settle in-flight calls
 * the same way — one message list, one worker-job event, one settle path — so
 * that machinery lives here. NOT a public header: it uses XS types, so it must
 * be included AFTER xsAll.h/xs.h, and it never crosses into Swift.
 *
 * Two peer flavors share the settle path, discriminated by ServiceEvent.payload:
 *   - native peer  (Swift-backed): value carried as UTF-8 JSON  (a Swift edge
 *     cannot xsDemarshall, so the payload stays JSON/bytes).
 *   - machine peer (another XS machine): value carried alien-marshalled, so two
 *     independent xsCreateMachine machines exchange it with no shared prep.
 */
#ifndef bridgeInternal_h
#define bridgeInternal_h

/* Payload flavor of a ServiceEvent (how the settle path reads its value). */
enum { XSB_PAYLOAD_JSON = 0, XSB_PAYLOAD_MARSHALLED = 1 };

/* One in-flight async call. resolve/reject/onToken are XS function references
 * kept in C memory and rooted via fxRemember; the record's address must be
 * stable while remembered (the GC root list points at &resolve etc). onToken is
 * present only for streaming calls and lives for the whole call. XS-thread only. */
typedef struct ServiceMessage {
    uint32_t id;
    txSlot resolve;
    txSlot reject;
    txSlot onToken;
    int hasOnToken;
    struct ServiceMessage* next;
} ServiceMessage;

typedef struct XSBridge {
    xsMachine* machine;
    void* swiftContext;     /* opaque Swift pointer (xsBridgeSet/GetContext) */
    void* servicePending;   /* service: server-side in-flight requests (ServicePending*) */
    uint32_t nextId;
    ServiceMessage* messages;   /* in-flight calls, XS-thread only */

    uint32_t rememberCount; /* leak accounting */
    uint32_t forgetCount;

    int moduleStatus;       /* xsBridgeRunModule: 0 pending, 1 fulfilled, 2 rejected */
    char* moduleError;      /* rejection message (malloc'd), XS-thread only */
    char* moduleParams;     /* JSON for the default export (malloc'd or NULL) */
} XSBridge;

/* A unit of work handed to the XS thread via mac_xs.c's worker-job queue. The
 * txWorkerJob header MUST be first: the queue links and c_free's the struct by
 * that header. One event settles (or streams a token to, or requests) one call;
 * the job's callback pointer selects the operation (ServiceEventResolve/Reject/
 * Token, or service.c's request handler). */
typedef struct ServiceEvent {
    txWorkerJob job;       /* { next, callback } — must be first */
    int payload;           /* XSB_PAYLOAD_JSON | XSB_PAYLOAD_MARSHALLED */
    uint32_t id;           /* the call id to settle / stream / echo back */
    char* json;            /* JSON value (owned) — XSB_PAYLOAD_JSON */
    void* blob;            /* alien-marshalled value (owned) — XSB_PAYLOAD_MARSHALLED */
    struct XSBridge* client;   /* service request only: the bridge to reply to */
    char* method;          /* service request only: method name (owned) */
    char* module;          /* Thread/Service request only: module specifier (owned) */
} ServiceEvent;

/* Message-list bookkeeping (XS-thread only). Unlink removes and returns the
 * record for a final settlement; Find leaves it linked (streamed tokens). */
ServiceMessage* xsBridgeUnlinkMessage(XSBridge* bridge, uint32_t id);
ServiceMessage* xsBridgeFindMessage(XSBridge* bridge, uint32_t id);

/* Drain the microtask queue to quiescence within the current host frame, so a
 * settled call's `await` continuation has run before pendingCount drops. */
void xsBridgeDrainPromises(txMachine* the);

/* Unified settle worker-job callbacks (txWorkerCallback), defined in settle.c.
 * Used by BOTH peers: the native peer posts them with an XSB_PAYLOAD_JSON event
 * (xsServiceResolve / xsServiceReject), the machine peer with an
 * XSB_PAYLOAD_MARSHALLED event (the service reply). Each unlinks the call,
 * resolves/rejects, forgets its roots. ServiceEventToken streams one reverse-
 * channel token (native peer only; machine services do not stream). */
void ServiceEventResolve(void* machine, void* job);
void ServiceEventReject(void* machine, void* job);
void ServiceEventToken(void* machine, void* job);

/* Free the server-side in-flight request list (bridge->servicePending), owned by
 * service.c. Called from xsBridgeDeleteMachine so a torn-down server machine
 * with unanswered requests leaks nothing. */
void xsServiceFreePending(XSBridge* bridge);

#endif /* bridgeInternal_h */
