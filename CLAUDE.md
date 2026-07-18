# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A reusable Swift library (**`XSBridgeKit`**) that embeds the **XS (Moddable)** JavaScript
engine and lets JS call back into **Swift** — synchronously, asynchronously, and as a
**stream** of tokens — on macOS, without memory corruption or crashes. The central
guarantee it upholds:

> A JS `await host.echo(...)` is resolved by Swift work running on another queue, with the
> JS continuation correctly resuming, stably and repeatably.

It grew out of a validated proof of concept covering lifecycle, async, streaming,
concurrency and GC-under-stress; the `xsBridgeTest` harness keeps that coverage as the
regression suite.

Target: **macOS, Apple Silicon (M3 Pro)**, Swift toolchain. The library has no UI; the
`xsBridgeTest` executable is a CLI harness that doubles as the regression suite.

## How it works

**Consumer C host functions.** The C layer hardcodes no host capabilities and installs
nothing — even `print` is consumer-supplied (the demo host and the CLI each install
their own). A consumer supplies its own small C target (compiled with the **same XS
defines** as `XSBridge` — the `txMachine` ABI depends on them) whose install function
(`xsNewHostFunction` + `xsSet`, run via `XSEngine.withMachine`) registers each native
capability directly. Each C host function marshals its arguments to plain C values, and —
for async calls — creates its Promise via `xsServicePromise` (declared in `bridgeXS.h`),
then hands `(bridge, id, params)` to its Swift `@_cdecl` counterpart; Swift settles later
with `xsServiceResolve` / `xsServiceReject` / `xsServiceEmit`. There is no JS prelude, no string-keyed
dispatch, no Swift protocol: the pair `xsBridgeTestC/demoHost.c` + `DemoHost.swift`
(echo/stream/fail/add, plus a multi-machine service call) is the reference pattern, kept
as the regression suite.

**Dedicated-thread runtime.** Each `XSEngine` owns a private background `Thread` with its
own `CFRunLoop` (`RunLoopThread`). The machine is created on it; every machine access is
marshalled there via `loop.sync`; async completions wake the same run loop. The XS machine
is never touched from the caller's (e.g. UI) thread — preserving the single-threaded XS
invariant.

**Library split.** The reusable Swift API lives in its own `XSBridgeKit` library target
(`Sources/XSBridgeKit/XSEngine.swift`), exported via
`products: [.library(name: "XSBridgeKit", …)]` and depending on the C `XSBridge` target.
Consumers `import XSBridgeKit` (plus `XSBridge` for the flat settle functions).
`xsBridgeTest` (harness + `DemoHost`) depends on `XSBridgeKit` + `XSBridge` +
`xsBridgeTestC`. Public API: `XSEngine`, `XSError`.

**Snapshot (persist / restore the JS heap).** `engine.writeSnapshot() -> Data` serializes
the whole machine (`fxWriteSnapshot`); `XSEngine(snapshot:)` restores it in a fresh process
(`fxReadSnapshot`, which rebuilds the mac_xs platform and takes our `XSBridge*` context) —
fast startup + state persistence across launches. Write requires idle (`pendingCount == 0`:
in-flight calls settle in Swift, off the heap). The engine references host C functions in
the heap **by index** into a callback table, so the consumer registers a frozen, append-only
`XSBridgeRegisterHostTable(name, callback)`; each snapshot carries its ordered name list and
a restore accepts a prefix-compatible superset (append safe, reorder/removal rejected). Two
build requirements: `mxSnapshot` (defined in `Package.swift`) makes the engine
snapshot-clean (strings copied into the heap, deterministic chunk layout); and `bridge.c`
supplements `snapshot->callbacks` with a few engine built-ins this Moddable checkout installs
but omits from `xsSnapshot.c`'s `gxCallbacks` (`fx_ArrayBuffer_fromString`,
`fx_String_fromArrayBuffer`) — recheck that list on a Moddable bump.

**Streaming over a reverse channel.** `host.stream(prompt, onToken)` roots `onToken` for the
whole call (3 roots total: `xsServicePromise(the, &xsArg(1))`). Swift emits tokens via
`xsServiceEmit` — a worker job whose `ServiceEventToken` callback delivers
`onToken(delta)` while keeping the call open; a final `xsServiceResolve` / `xsServiceReject`
(the `ServiceEventResolve` / `ServiceEventReject` callbacks) settles and forgets all roots.
Tokens use `xsBridgeFindMessage` (non-unlinking), settlements use `xsBridgeUnlinkMessage`.

**Reject path & GC.** `host.fail` exercises the reject path; `xsBridgeCollectGarbage` forces
GC on the XS thread and `runUntilIdleForcingGC` drives a forced full GC on every run-loop
turn — proving the C-rooted slots survive collection at scale, with concurrent out-of-order
completion and no id crosstalk. `DemoHost` uses a small `callLatency` (5 ms, echo/fail) and a
larger `streamLatency` (50 ms, between tokens).

The machine **context is a `XSBridge*`** (allocated in `xsBridgeCreateMachine`), holding:
the in-flight `ServiceMessage` records (`{id → (resolve,reject)}`), remember/forget counters,
module status, and `swiftContext` (the unretained `XSEngine` pointer, set via
`xsBridgeSetContext`, recoverable from consumer `@_cdecl` functions via
`xsBridgeGetContext`). The `print` capture asserted by the harness lives in
`xsBridgeTestC` (`xsBridgeTestOutputCount/At`), not in the bridge.

Async flow: JS `host.echo(x)` enters the consumer's C host function, which stringifies the
argument, calls `xsServicePromise` — creates the Promise **in C** (`fxNewPromiseCapability`),
copies resolve/reject into a malloc'd record and `fxRemember`s them **before any further
allocation** (so GC tracks/relocates them), sets `xsResult` to the promise — then hands
`(bridge, id, json)` to its Swift `@_cdecl` function. Swift works on a background
`DispatchQueue`, then `xsServiceResolve` / `xsServiceReject` (bg thread) posts a worker job and wakes the XS
run loop. The settle callback `ServiceEventResolve` / `ServiceEventReject` (XS thread, shared
`xsServiceSettle`) settles via `xsCallFunction1(xsAccess(rec->resolve),…)`, `fxForget`s, frees
the record, and drains `fxRunPromiseJobs` to resume the `await`.

Key rooting rule: a remembered slot must live in stable C memory and be rooted *before*
any allocating XS call — the GC root list (`the->cRoot`) points at `&rec->resolve`. The C
host functions and the job callback are the only places that touch XS; Swift never
sees an `xsSlot`. The harness drives the loop with `runUntilIdle` (polls until
`xsBridgePendingCount == 0`).

Key build detail: the platform header is **`mac_xs.h`** (`XSPLATFORM="mac_xs.h"`), and the
macOS port **`mac_xs.c`** is compiled. It provides the run-loop integration —
`fxCreateMachinePlatform`/`fxDeleteMachinePlatform`, the cross-thread worker-job queue
(`fxQueueWorkerJob`) and the promise run-loop source — plus module loading
(`mxUseDefaultFindModule`/`LoadModule`). `bridge.c` only supplies `fxAbort` (which
`mac_xs.c` omits; it normally comes from `xst.c`, which we exclude). The shared-timer
functions are not needed: `mac_xs.h` defines `mxUseGCCAtomics`, which compiles out the
shared-timer paths in `xsAtomics.c`. Because `mac_xs.c::fxQueuePromiseJobs` signals a
run-loop source instead of setting `the->promiseJobs`, `bridge.c` drains microtasks
explicitly via `mxPendingJobs` (`xsBridgeDrainPromises`) inside each settlement's host frame,
so `xsBridgePendingCount == 0` always implies the `await` continuations have run.

## Architecture

The bridge mirrors the proven pattern in Moddable's `piuService.c` (used as a *pattern
reference only* — it is NOT compiled here, since it depends on the preparation/clone
flow). The machine is created with `xsCreateMachine` (full engine **with parser**, like
`xst`), not via `fxCloneMachine`.

```
Package.swift             # XS compile flags (from the xst mac makefile), shared by all C targets
Sources/
  XSBridge/               # C target: XS sources + mac platform + the bridge shim
    include/module.modulemap   # exposes bridge.h to Swift
    include/bridge.h           # flat C API, NO XS macros leak across it
    include/bridgeXS.h         # XS-typed helpers (xsServicePromise) — textual include for C targets, never Swift
    include/bridgeInternal.h   # C-target internals shared by bridge.c + service.c (structs, ServiceEvent, settle callbacks) — never Swift
    xs/                        # symlinks to $MODDABLE/xs incl. platforms/mac_xs.c (git-ignored; see scripts/link-moddable.sh)
    bridge.c                   # machine lifecycle, xsServicePromise, module loader, native-peer settlement via worker jobs (mac_xs.c)
    service.c                  # machine↔machine service peer (alien-marshalled), reusing the same settle path
  XSBridgeKit/            # Swift library (public reusable API; consumers import this)
    XSEngine.swift             # Swift wrapper; dedicated thread + CFRunLoop per machine (RunLoopThread)
  xsBridgeTestC/          # C side of the demo host (consumer host-function pattern)
    demoHost.c                 # print (+capture) + host.echo/stream/fail/add — xsServicePromise + @_cdecl calls into Swift
  xsBridgeTest/           # Swift executable: runner + test harness
    DemoHost.swift             # Swift side of the demo host: @_cdecl entry points (regression suite)
    main.swift                 # runs the test agents, asserts, exits non-zero on any failure
agents/                   # JS test scripts: echo.js, stream.js, concurrent.js, error.js, sequential.js
scripts/link-moddable.sh  # links the curated XS source subset from $MODDABLE into Sources/XSBridge/xs/
```

The XS sources are **not vendored**: `scripts/link-moddable.sh` symlinks the exact
curated subset (`xs/sources`, `xs/includes`, the platform dispatch headers
`xsPlatform.h`/`xsHost.h`, and the macOS port `mac_xs.h`+`mac_xs.c`) from `$MODDABLE/xs`
into `Sources/XSBridge/xs/`. Those links are git-ignored. SwiftPM compiles `.c` through the
directory symlinks; only `sources/` and `platforms/mac_xs.c` carry compiled units, which is
why `platforms/` is linked file-by-file (its other `.c` — every other platform port — must
not be compiled). `fdlibm` is not linked: the macOS port uses the system `libm`
(`xsPlatform.h` maps `c_sin` → `sin`, etc.); fdlibm is only for embedded ports.

The async bridge: the Promise is created **in C** by `xsServicePromise`
(`fxNewPromiseCapability`), which `fxRemember`s `resolve`/`reject` (+ optional `onToken`),
generates an id, and sets `xsResult` to the promise; the consumer's host function then
posts `(bridge, id, params)` to Swift. Swift does the work off the XS run loop, then posts
a **worker job** via `fxQueueWorkerJob` (mac_xs.c), which signals the XS thread's run
loop. The settle callback (`ServiceEventResolve` / `ServiceEventReject`, sharing
`xsServiceSettle`) re-enters with `xsBeginHost`, looks up `(resolve, reject)` by id, settles
the Promise, `fxForget`s, and **drains promise jobs** (`fxRunPromiseJobs` via
`xsBridgeDrainPromises`) to resume the `await` continuation.

**One settle path, two peers (the "service" layer).** The async settlement above is shared
by both the native peer (Swift-backed host functions, `bridge.c`) and the machine peer
(machine↔machine service calls, `service.c`). Both post a `ServiceEvent` handled by the
same `ServiceEventResolve` / `ServiceEventReject` callbacks; the only difference is
`ServiceEvent.payload` — the native peer carries the value as **UTF-8 JSON** (a Swift edge
cannot `xsDemarshall`), the machine peer as an **alien-marshalled blob** (self-contained,
by name, so two independent `xsCreateMachine` machines exchange it with no shared prep).
Public API: `xsServicePromise` / `xsServiceResolve` / `xsServiceReject` / `xsServiceEmit`
(native), `xsServiceInvoke` / `xsServiceLink` / `xsServiceInstallServer` (machine).

## Critical invariants (must always hold)

1. **No XS exception crosses a Swift frame.** All `xsTry`/`xsCatch` stays in C; every
   Swift→XS entry is wrapped in `xsBeginHost`/`xsEndHost`. A JS error becomes a clean
   error result returned to Swift — never a `longjmp` into Swift.
2. **No `xsSlot` crosses into Swift.** Swift only ever sees opaque ids (`uint32_t`) and
   marshaled values (**UTF-8 JSON**). All slot lifecycle stays in C.
3. **Single-threaded XS.** All machine calls happen on one thread/run loop. Swift work
   runs *off* that run loop and returns only via the run-loop signal.
4. **Systematic rooting.** `resolve`/`reject`/`onToken` are `xsRemember`'d on intake and
   `xsForget`'d exactly once at settle. Verify no leak (id table empty, remember/forget
   counters balanced at the end of each run).

## Build & run

Requires a local Moddable checkout (recent master); link it once before building:

```bash
export MODDABLE=/path/to/moddable
./scripts/link-moddable.sh          # symlinks the XS sources into Sources/XSBridge/xs/
swift build -c release              # builds in release on Apple Silicon
swift run xsBridgeTest              # runs the harness; exits non-zero if any criterion fails
```

`main.swift` runs each agent, asserts its criterion, and exits non-zero on failure —
designed for CI and non-interactive Claude Code runs. There is no separate test framework;
the harness *is* the test suite. To exercise a single behaviour, run the corresponding
agent in `agents/` from the harness.

The C target is based on the macOS port: `XSPLATFORM="mac_xs.h"` and `platforms/mac_xs.c`
is compiled. The remaining `#define`s in `Package.swift` (`mxDebug`,
`mxStringInfoCacheLength`, `mxSnapshot`) tune the engine — `mxSnapshot` is ABI-affecting
(txChunk layout) so it must stay identical across every C target; the platform-specific
`mxUse*` defines come from
`mac_xs.h` itself. The bridge was originally modelled on the `xst` target
(`$MODDABLE/xs/makefiles/mac`, `$MODDABLE/documentation/xs/xst.md`), then rebased onto
`mac_xs` to reuse the upstream run-loop integration.

## Behavioral guidelines

Behavioral guidelines to reduce common LLM coding mistakes. Merge with the
project specifics below. **Tradeoff:** these bias toward caution over speed. For
trivial tasks, use judgment.

### 1. Think before coding
Don't assume. Don't hide confusion. Surface tradeoffs.
- State assumptions explicitly. If uncertain, ask.
- If multiple interpretations exist, present them — don't pick silently.
- If a simpler approach exists, say so. Push back when warranted.
- If something is unclear, stop. Name what's confusing. Ask.

### 2. Simplicity first
Minimum code that solves the problem. Nothing speculative.
- No features beyond what was asked.
- No abstractions for single-use code.
- No "flexibility"/"configurability" that wasn't requested.
- No error handling for impossible scenarios.
- If you write 200 lines and it could be 50, rewrite it.
- Test: "Would a senior engineer call this overcomplicated?" If yes, simplify.

### 3. Surgical changes
Touch only what you must. Clean up only your own mess.
- Don't "improve" adjacent code, comments, or formatting.
- Don't refactor what isn't broken. Match existing style.
- Notice unrelated dead code? Mention it — don't delete it.
- Remove imports/vars/functions that YOUR changes made unused.
- Don't remove pre-existing dead code unless asked.
- Test: every changed line should trace to the request.

### 4. Goal-driven execution
Define success criteria. Loop until verified.
- "Add validation" → "Write tests for invalid inputs, then make them pass."
- "Fix the bug" → "Write a test that reproduces it, then make it pass."
- For multi-step tasks, state a brief plan with a verify step each.
- **When success criteria are well-defined (a test passes, output matches),
  loop autonomously without asking — reserve questions for genuine ambiguity in
  the goal itself.** (This project values uninterrupted loops on clear goals.)

Working if: fewer unnecessary diff lines, fewer rewrites for overcomplication,
clarifying questions come *before* implementation rather than after mistakes.
