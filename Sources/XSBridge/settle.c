/*
 * settle.c — the shared async-call core, neutral to both peers.
 *
 * Opening a call (xsServicePromise: create the Promise, root resolve/reject,
 * link a ServiceMessage) and settling it (the ServiceEvent worker-job callbacks
 * ServiceEventResolve / ServiceEventReject / ServiceEventToken) are identical
 * whether the other end is the native (Swift) peer in bridge.c or the machine
 * peer in service.c. Both of those depend on this file; this file depends on
 * neither. The only per-peer difference is ServiceEvent.payload — a native peer
 * carries UTF-8 JSON, a machine peer an alien-marshalled blob — handled in the
 * one branch inside xsServiceSettle.
 */
#include "xsAll.h"
#include "xs.h"

#include "bridge.h"
#include "bridgeXS.h"
#include "bridgeInternal.h"

#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Opening a call.
 * ------------------------------------------------------------------------- */

/* Create the Promise for an in-flight call: build a promise capability, copy
 * resolve/reject (+ optional onToken) into stable C memory and root them BEFORE
 * any further allocation (the stack temporaries keep them alive up to that
 * point), link the message record, set xsResult to the promise and return the
 * id. Must run inside a host frame (a C host function). */
uint32_t xsServicePromise(xsMachine* the, xsSlot* onToken)
{
    XSBridge* bridge = (XSBridge*)xsGetContext(the);
    ServiceMessage* rec = (ServiceMessage*)calloc(1, sizeof(ServiceMessage));
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

/* ---------------------------------------------------------------------------
 * Message-list bookkeeping + microtask drain (XS-thread only).
 * ------------------------------------------------------------------------- */

ServiceMessage* xsBridgeUnlinkMessage(XSBridge* bridge, uint32_t id)
{
    ServiceMessage** addr = &bridge->messages;
    ServiceMessage* p;
    while ((p = *addr)) {
        if (p->id == id) {
            *addr = p->next;
            return p;
        }
        addr = &p->next;
    }
    return NULL;
}

ServiceMessage* xsBridgeFindMessage(XSBridge* bridge, uint32_t id)
{
    for (ServiceMessage* p = bridge->messages; p; p = p->next)
        if (p->id == id)
            return p;
    return NULL;
}

/* Drain the microtask (promise jobs) queue to quiescence, within a host frame.
 * mac_xs.c's fxQueuePromiseJobs signals a run-loop source rather than setting a
 * flag, so we drain explicitly here to guarantee that once a call's message
 * record is gone, its `await` continuation has already run (the harness treats
 * pendingCount == 0 as "fully settled"). Must be called inside xsBeginHost. */
void xsBridgeDrainPromises(txMachine* the)
{
    xsTry {
        while (mxPendingJobs.value.reference->next)
            fxRunPromiseJobs(the);
    }
    xsCatch {
    }
}

/* ---------------------------------------------------------------------------
 * Settling a call — the ServiceEvent worker-job callbacks, shared by both peers.
 * ------------------------------------------------------------------------- */

/* Free a ServiceEvent's owned payload (mac_xs.c c_free's the job struct itself). */
static void xsServiceEventFree(ServiceEvent* j)
{
    if (j->json) free(j->json);
    if (j->blob) free(j->blob);
}

/* Shared final-settlement path for both peers: unlink the call, resolve or
 * reject it with the call's value, forget its roots, then drain promise jobs so
 * the awaiting continuation runs. The value is read per the event's payload
 * flavor — a native peer carries UTF-8 JSON (JSON.parse), a machine peer an
 * alien-marshalled blob (xsDemarshallAlien). mac_xs.c invokes this on the XS
 * thread (unframed) via ServiceEventResolve / ServiceEventReject. */
static void xsServiceSettle(void* machine, void* job_, int reject)
{
    ServiceEvent* j = (ServiceEvent*)job_;
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(2);
        ServiceMessage* rec = xsBridgeUnlinkMessage(bridge, j->id);
        if (rec) {
            xsTry {
                if (j->payload == XSB_PAYLOAD_MARSHALLED) {
                    xsVar(1) = j->blob ? xsDemarshallAlien(j->blob) : xsUndefined;
                } else {
                    xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
                    xsVar(1) = xsCall1(xsVar(0), xsID("parse"),
                                       xsString(j->json ? j->json : "null"));
                }
                txSlot* fn = reject ? &rec->reject : &rec->resolve;
                xsCallFunction1(xsAccess(*fn), xsUndefined, xsVar(1));
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
        xsBridgeDrainPromises(the);
    }
    xsEndHost((xsMachine*)machine);

    xsServiceEventFree(j);
}

void ServiceEventResolve(void* machine, void* job_) { xsServiceSettle(machine, job_, 0); }
void ServiceEventReject(void* machine, void* job_)  { xsServiceSettle(machine, job_, 1); }

/* Reverse channel (native peer only): invoke the call's onToken(delta) and keep
 * the call open. Non-unlinking; the call is settled later by a Resolve/Reject. */
void ServiceEventToken(void* machine, void* job_)
{
    ServiceEvent* j = (ServiceEvent*)job_;
    XSBridge* bridge = (XSBridge*)xsGetContext((xsMachine*)machine);

    xsBeginHost((xsMachine*)machine);
    {
        xsVars(2);
        ServiceMessage* rec = xsBridgeFindMessage(bridge, j->id);
        if (rec && rec->hasOnToken) {
            xsTry {
                xsVar(0) = xsGet(xsGlobal, xsID("JSON"));
                xsVar(1) = xsCall1(xsVar(0), xsID("parse"), xsString(j->json));
                xsCallFunction1(xsAccess(rec->onToken), xsUndefined, xsVar(1));
            }
            xsCatch {
            }
        }
        xsBridgeDrainPromises(the);
    }
    xsEndHost((xsMachine*)machine);

    xsServiceEventFree(j);
}
