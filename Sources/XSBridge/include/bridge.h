/*
 * bridge.h — flat C API exposed to Swift.
 *
 * Invariant (PLAN §40.2): nothing XS-specific crosses this header. Swift only
 * ever sees plain C types — an opaque machine handle (void*), opaque ids
 * (uint32_t), C strings (UTF-8 JSON). No xsSlot, no xsMachine, no XS macros.
 */
#ifndef XSB_BRIDGE_H
#define XSB_BRIDGE_H

#include <stdint.h>

/* Phase 0 smoke test: returns 42, proves the C target links into Swift. */
int32_t xsb_smoke(void);

/* ---- Machine lifecycle ---- */

/* Create a full XS machine (engine with parser) plus its async bridge and a
 * CFRunLoopSource on the *current* run loop. Returns an opaque handle or NULL. */
void* xsb_create_machine(void);

/* Destroy a machine and its bridge. Caller must ensure no async work is still
 * in flight (no pending ids) before deleting. */
void xsb_delete_machine(void* machine);

/* Set the opaque Swift engine pointer recovered by host dispatch callbacks. */
void xsb_set_context(void* machine, void* context);

/* Recover the opaque Swift context from the bridge pointer passed to the async
 * dispatch callbacks (xsb_dispatch / xsb_dispatch_sync). */
void* xsb_context_of(void* bridge);

/* ---- Synchronous eval (Phase 1) ---- */

/* Evaluate `src`. On success returns 1, *out_json = JSON result (or "undefined").
 * On JS error returns 0, *out_err = the message. Free returned strings with
 * xsb_free. A JS exception is captured here and never crosses into Swift. */
int xsb_eval(void* machine, const char* src, char** out_json, char** out_err);

/* Free a string returned by xsb_eval. */
void xsb_free(char* s);

/* ---- Async bridge (Phase 3) ---- */

/* Called from a Swift background thread to settle an in-flight async call by id.
 * `success` non-zero -> resolve(JSON.parse(json)); zero -> reject(...). The
 * result is queued and the machine's run loop is woken to settle on its own
 * thread. Thread-safe. */
void xsb_complete(void* bridge, uint32_t id, int success, const char* json);

/* Called from a Swift background thread to stream one token (the reverse
 * channel): invokes the JS onToken(JSON.parse(json)) and keeps the call open
 * until a later xsb_complete settles it. Thread-safe. */
void xsb_emit_token(void* bridge, uint32_t id, const char* json);

/* Number of in-flight async calls (ids awaiting settlement). XS-thread only. */
int xsb_pending_count(void* machine);

/* Force a full GC on the XS thread (stress test: verifies roots survive). */
void xsb_collect_garbage(void* machine);

/* Leak accounting: total xsRemember vs xsForget calls (must match when idle). */
void xsb_debug_counts(void* machine, uint32_t* remembered, uint32_t* forgotten);

/* Captured print() output. */
int xsb_output_count(void* machine);
const char* xsb_output_at(void* machine, int index);

#endif /* XSB_BRIDGE_H */
