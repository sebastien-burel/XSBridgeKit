# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A single Swift package, **`KaozKit`**, in two layers. At the bottom is a reusable JS↔Swift
engine bridge (**`KaozJSCore`** + **`KaozJS`**) that embeds the **XS (Moddable)** JavaScript
engine and lets JS call back into **Swift** — synchronously, asynchronously, and as a
**stream** of tokens — on macOS, without memory corruption or crashes. The central
guarantee the engine upholds:

> A JS `await host.echo(...)` is resolved by Swift work running on another queue, with the
> JS continuation correctly resuming, stably and repeatably.

On top of that engine is an **autonomous-agent runtime** (**`KaozKit`**): an agent is a JS
module (`export function run(input)`) that drives an LLM, calls tools, and reads/writes
memory through a `host.*` surface. A project embedding **only JavaScript** depends on
`KaozJS`; an **agent** project depends on `KaozKit`, which pulls the engine in.

The engine grew out of a validated proof of concept covering lifecycle, async, streaming,
concurrency and GC-under-stress; the `KaozJSTests` harness keeps that coverage as the
engine regression suite. This package was formed by merging the former XSBridge/XSBridgeKit
socle and the TyKaozKit agent library (commit `970292e`); internal C symbols (`struct
XSBridge`, the `xsBridge*`/`xsService*` API, the snapshot signature) were left unchanged, so
existing snapshots stay compatible — which is why the C code and several Swift symbols still
carry `xsBridge*` / `TyKaoz*` names.

Target: **macOS 26+, Apple Silicon**, Swift toolchain. The library has no UI; `kaoz` is a
headless agent CLI / resident daemon, and `KaozJSTests` is a CLI harness that doubles as the
engine regression suite.

## Layered products

```
KaozJSCore (C)  — XS engine + the xsService* async-settle bridge
KaozJS          — Swift XSEngine (dedicated thread + CFRunLoop, snapshot, module roots)
KaozHostC (C)   — the agent's XS host functions (host.llm/tool/memory/schedule)
KaozKit         — agent runtime: providers, tools, memory, channels, persona
KaozMLX         — MLX local-inference providers (heavy deps, opt-in)
kaoz            — headless CLI / resident daemon
```

The rest of this file documents the engine layer first (unchanged internals, renamed
targets), then the agent layer built on top.

## How it works (engine layer: KaozJSCore + KaozJS)

**Consumer C host functions.** The C layer hardcodes no host capabilities and installs
nothing — even `print` is consumer-supplied (the demo host and each consumer install
their own). A consumer supplies its own small C target (compiled with the **same XS
defines** as `KaozJSCore` — the `txMachine` ABI depends on them) whose install function
(`xsNewHostFunction` + `xsSet`, run via `XSEngine.withMachine`) registers each native
capability directly. Each C host function marshals its arguments to plain C values, and —
for async calls — creates its Promise via `xsServicePromise` (declared in `bridgeXS.h`),
then hands `(bridge, id, params)` to its Swift `@_cdecl` counterpart; Swift settles later
with `xsServiceResolve` / `xsServiceReject` / `xsServiceEmit`. There is no JS prelude, no string-keyed
dispatch, no Swift protocol: the pair `KaozJSTestC/demoHost.c` + `DemoHost.swift`
(echo/stream/fail/add, plus a multi-machine service call) is the reference pattern, kept
as the engine regression suite. `KaozHostC/tykaozHost.c` + `TyKaozHost.swift` is the real
consumer — the agent's `host.*` surface built on the very same pattern.

**Dedicated-thread runtime.** Each `XSEngine` owns a private background `Thread` with its
own `CFRunLoop` (`RunLoopThread`). The machine is created on it; every machine access is
marshalled there via `loop.sync`; async completions wake the same run loop. The XS machine
is never touched from the caller's (e.g. UI) thread — preserving the single-threaded XS
invariant.

**Library split.** The reusable Swift engine API lives in its own `KaozJS` library target
(`Sources/KaozJS/XSEngine.swift`), exported via `products: [.library(name: "KaozJS", …)]`
and depending on the C `KaozJSCore` target. Consumers `import KaozJS` (plus `KaozJSCore`
for the flat settle functions). `KaozJSTests` (harness + `DemoHost`) depends on `KaozJS` +
`KaozJSCore` + `KaozJSTestC`. Public engine API: `XSEngine`, `XSCreation`, `XSError`.

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
`KaozJSTestC` (`xsBridgeTestOutputCount/At`), not in the bridge.

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
Package.swift             # XS compile flags + product/target graph; xsDefines shared by all C targets
Sources/
  KaozJSCore/             # C target: XS sources + mac platform + the bridge shim
    include/module.modulemap   # exposes bridge.h to Swift
    include/bridge.h           # flat C API, NO XS macros leak across it
    include/bridgeXS.h         # XS-typed helpers (xsServicePromise) — textual include for C targets, never Swift
    include/bridgeInternal.h   # C-target internals shared by settle.c/bridge.c/service.c (structs, ServiceEvent, settle callbacks) — never Swift
    xs/                        # symlinks to $MODDABLE/xs incl. platforms/mac_xs.c (git-ignored; see scripts/link-moddable.sh)
    settle.c                   # shared async-call core: xsServicePromise + message list + the ServiceEvent settle callbacks (peer-neutral)
    bridge.c                   # machine lifecycle, module loader, snapshot, and the NATIVE (Swift) peer (JSON posters) — depends on settle.c
    service.c                  # the MACHINE↔MACHINE peer (alien-marshalled) + JS-initiated Thread/Service spawn — depends on settle.c
  KaozJS/                 # Swift engine library (public reusable API; consumers import this)
    XSEngine.swift             # Swift wrapper; dedicated thread + CFRunLoop per machine (RunLoopThread)
  KaozHostC/              # C host functions for the agent (consumer of the engine)
    tykaozHost.c               # host.log/__chat/tool.*/memory.*/schedule/every/cancel/usage — xsServicePromise + @_cdecl into Swift
    httpHost.c                 # the native __http(request,onChunk) primitive (backs the JS providers + XHR shim)
    jsProviderHost.c           # __emit/__done/__providerError channel for a JSProvider engine
  KaozKit/                # Swift agent runtime (the flagship product; import KaozKit)
    Agents/                    # AgentRuntime (one-shot), AgentHost (resident+snapshot), TyKaozHost (host.* backing),
                               #   TyKaozThreads (sub-agent factory), AgentModuleStaging, ModuleResolver, JSToolBundle
    Providers/                 # LLMProvider + families: Anthropic/Google/Ollama/OpenAI/OpenAICompatible
                               #   (DeepSeek/Mistral/Qwen/ZAI/LocalOpenAI)/Apple/ComfyUI/Embedding/JS
    Tools/                     # Tool + ToolRegistry; read (ReadFile/ListDirectory/GrepFiles/CurrentLocation),
                               #   Actuation/ (Write/Edit/Shell/HTTPRequest), Email/, FileSpaces/, Memory/, Plugins/
    Channels/WebhookServer.swift  # inbound HTTP → resident agent delivery
    Support/                   # MemoryStoring, Subprocess
    Resources/js/              # JS loaded at runtime via Bundle.module: agent-orchestrator.js, provider-orchestrator.js,
                               #   {anthropic,google,ollama,openai}.js, xmlhttprequest.js, tools/{datetime,fetch-url,web-search,http}.js
  KaozMLX/                # Swift, opt-in: MLX local inference (MLXLLMProvider/MLXEmbeddingProvider + Models/ store & catalog)
  kaoz/                   # Swift executable: headless agent CLI / resident daemon (main.swift, CLIMemoryStore.swift)
  KaozJSTestC/            # C side of the engine demo host (consumer host-function pattern)
    demoHost.c                 # print (+capture) + host.echo/stream/fail/add — xsServicePromise + @_cdecl calls into Swift
  KaozJSTests/            # Swift executable: engine regression harness
    DemoHost.swift             # Swift side of the demo host: @_cdecl entry points (regression suite)
    main.swift                 # runs the test agents, asserts, exits non-zero on any failure
agents/                   # engine JS fixtures: echo.js, stream.js, concurrent.js, error.js, sequential.js, modules/
scripts/link-moddable.sh  # links the curated XS source subset from $MODDABLE into Sources/KaozJSCore/xs/
scripts/link-mlx-metallib.sh  # copies MLX's default.metallib next to the CLI build so `kaoz --provider mlx` works
```

The XS sources are **not vendored**: `scripts/link-moddable.sh` symlinks the exact
curated subset (`xs/sources`, `xs/includes`, the platform dispatch headers
`xsPlatform.h`/`xsHost.h`, and the macOS port `mac_xs.h`+`mac_xs.c`) from `$MODDABLE/xs`
into `Sources/KaozJSCore/xs/`. Those links are git-ignored. SwiftPM compiles `.c` through the
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

**One settle path, two peers (the "service" layer).** The async settlement above lives in
`settle.c` — a peer-neutral core (`xsServicePromise` + the message list + the `ServiceEvent`
callbacks `ServiceEventResolve`/`Reject`/`Token`) — reused by both the native peer (Swift-backed
host functions, `bridge.c`) and the machine peer (machine↔machine service calls, `service.c`).
Both `bridge.c` and `service.c` depend on `settle.c`, never on each other. Both post a
`ServiceEvent` handled by the same callbacks; the only difference is `ServiceEvent.payload` —
the native peer carries the value as **UTF-8 JSON** (a Swift edge cannot `xsDemarshall`), the
machine peer as an **alien-marshalled blob** (self-contained, by name, so two independent
`xsCreateMachine` machines exchange it with no shared prep). Public API: `xsServicePromise` /
`xsServiceResolve` / `xsServiceReject` / `xsServiceEmit` (native peer); the machine peer is
driven from JS via `xsThreadInstall`'s `Thread` / `Service` globals (below).

**JS-initiated spawn (`Thread` / `Service`).** The machine peer is driven entirely from
the script (the piu model). `xsThreadInstall(machine)` adds two globals: `new Thread(name)`
spawns a fully-installed child engine (a consumer-supplied factory registered via
`xsBridgeRegisterThreadFactory` builds it — the socle installs nothing), and
`new Service(thread, moduleSpecifier)` returns a `Proxy` bound to that child; `await
svc.method(args)` creates the Promise **in JS**, hands its resolve/reject to
`__serviceInvoke` (rooted in a `ServiceMessage`, reusing `settle.c`), marshals the args and
posts a request. The child `import(moduleSpecifier)`s the module and calls its default
export; the reply settles through the same `ServiceEventResolve`/`Reject` path. A relative
(`./` / `../`) specifier is resolved against `globalThis.__moduleBase` in the `Service`
prelude (the child then `realpath`s it), so the runtime sets `__moduleBase` to the script's
directory. A `Thread` is a host object whose destructor tears the child engine down when it
is GC'd, so lifecycle follows JS reachability. Who spawns, how many, and how they are named
lives in the script.

**Module resolution (roots).** The filesystem loader (`fxFindModule` in `bridge.c`) resolves
a relative (`./`, `../`) specifier against the importer, as ES expects. On top of that a
consumer can register **roots** (`xsBridgeAddModuleRoot(prefix, dir)`, process-wide): a `""`
prefix is a default root for **bare** specifiers (`import "util"` → `<root>/util.{xsb,mjs,js}`,
searched in that order), a named prefix maps `<prefix>/x` to an external directory
(`import "modules/x"`). While any root is registered the loader is **confined** — every
bare/relative resolution (relative ones included) must land inside a root (no `../` escape) —
mirroring Moddable's `mcconfig` layout. An **absolute-path** specifier resolves only if it
lands inside a root **or** a registered **trusted prefix** (`xsBridgeAddTrustedModulePrefix`):
the roots are process-wide, so a confined agent's roots also govern the framework's own
engines (a JS provider, tool bundle, a sub-agent's orchestrator) which import their bundle
resources by absolute path — the consumer marks that bundle directory trusted so those imports
survive, while an agent's arbitrary `/abs/path` escape (in neither a root nor a trusted prefix)
is still rejected. With no root registered the loader keeps its plain realpath behaviour, so
this is opt-in. (`.xsa` archive roots are a planned follow-up.)

## The agent layer (KaozKit)

The agent runtime is a **consumer of the engine**, wired through exactly the mechanisms
above — it adds no new engine concepts. An agent is a JS module that `export`s `run(input)`
(one-shot) or `{ onMessage, onEvent, onTick }` (resident); its return value comes back to
Swift as JSON via `host.__report` / `host.__deliverResult`.

**Host surface.** `KaozHostC/tykaozHost.c` installs the `host.*` object (the reference
host-function pattern, `xsServicePromise` + `@_cdecl` into `TyKaozHost.swift`): `host.log`,
`host.__chat` (async LLM turn, streams tokens via `xsServiceEmit`), `host.tool.list`/`call`,
`host.memory.save`/`read`/`list`/`search`, `host.schedule`/`every`/`cancel` (self-scheduled
ticks), `host.usage`. `TyKaozHost.swift` holds the `@_cdecl` entry points; each recovers the
host from the bridge context and settles via `HostReply` (`xsServiceResolve`/`Reject`/`Emit`).
The ergonomic wrappers — `host.llm.chat`, `host.provider(id)`, `__runAgent`, `__deliver`,
`__callTool` — are a **JS shim** (`Resources/js/agent-orchestrator.js`, imported as a bundled
ES module by `XSEngine.tyKaoz(host:)`). Bundled JS is loaded by absolute path, so its
directory is registered as a **trusted module prefix** (`JSResource.registerTrustedPrefix`).

**Entry points (Swift).** `AgentRuntime` (`Agents/AgentRuntime.swift`) runs one agent on a
fresh engine and tears it down (`run` / `runRooted` / `runRootedSource` → JSON `String`).
`AgentHost` (`Agents/AgentHost.swift`) keeps one engine alive across many
`deliver(kind:payload:)` calls — the JS heap persists, `host.schedule` timers deliver ticks,
and `writeSnapshot()` / `init(snapshot:)` persist and restore the whole heap across
processes (snapshot mode needs `installThreads: false`, since the `Thread`/`Service` globals
reference host callbacks not in the frozen table). Both are constructed with a `makeProvider`
(run default), an optional `resolveProvider(id, options)` (JS-selected provider, secrets
injected in Swift), a `ProviderDescriptor` catalog, a `ToolRegistry`, a `MemoryStoring`, and
optional `tokenBudget` / `persona`. Sub-agents use the engine's `Thread`/`Service` spawn: the
factory registered via `TyKaozThreads.register` builds a child `TyKaozHost` with the same
wiring.

**Providers.** All conform to `LLMProvider` (streaming `chat(messages:tools:)` →
`StreamEvent`). `TyKaozHost.chat` runs the **tool-call loop** (provider → tool → provider, up
to `maxToolRounds`) off the XS thread on a `@MainActor` task, streaming text back via
`reply.emit` and settling with the final text. Native providers are pure Swift; **JS
providers** (`JSProvider` + `Resources/js/*.js`) run their HTTP/SSE in a JS engine over the
native `__http` primitive (`httpHost.c`) with an `XMLHttpRequest` shim, bridging events to
Swift through `jsProviderHost.c` (`__emit`/`__done`/`__providerError`). `KaozMLX` adds
on-device MLX providers behind its own product so plain `KaozKit` consumers don't pull the
heavy deps.

**Tools & memory.** `Tool` + `ToolRegistry`. Read tools (`ReadFile`/`ListDirectory`/
`GrepFiles`) are confined to `AuthorizedRoot`s; actuation (`WriteFile`/`EditFile`/`Shell`/
`HTTPRequest`) is opt-in and separately confined; `EmailTools` speak IMAP/SMTP; `HTTPPluginTool`
builds tools from a declarative `PluginManifest`. `SemanticMemoryStore` ranks notes by
embedding similarity behind `MemoryStoring`/`MemoryRetrieving`. `WebhookServer` delivers
inbound HTTP bodies to a resident agent.

**CLI (`kaoz`).** `Sources/kaoz/main.swift` is the canonical worked example: it maps
`--provider`/env secrets to concrete providers via `resolveProvider`, assembles the tool set
from opt-in flags (`--root`/`--allow-write`/`--allow-shell`/`--allow-http`/`--email`), and
runs `AgentRuntime.runRooted` (or an `AgentHost` for `--resident`/`--daemon`/`--webhook`,
with `--state` snapshotting the heap).

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

Agent-layer invariants (built on the four above):

5. **Secrets never reach JS.** API keys and credentials live in Swift (env → `resolveProvider`
   / tool config). JS names a provider by id and passes non-secret options (`model`, `baseURL`);
   the Swift resolver injects the key.
6. **Actuation is opt-in and confined.** Write/shell/http/email tools are added only when the
   consumer grants them, each confined to its authorized roots/hosts; read tools are confined
   to `AuthorizedRoot`s. An agent's module resolution is confined to its roots (bundle JS aside,
   marked as a trusted prefix).

## Build & run

Requires a local Moddable checkout (recent master); link it once before building:

```bash
export MODDABLE=/path/to/moddable
./scripts/link-moddable.sh          # symlinks the XS sources into Sources/KaozJSCore/xs/
swift build -c release              # builds in release on Apple Silicon (macOS 26+)
swift run -c release KaozJSTests    # engine regression harness; non-zero exit on any failure
swift run -c release kaoz agent.js --provider anthropic --input '{"question":"…"}'
```

`KaozJSTests/main.swift` runs each engine fixture, asserts its criterion, and exits non-zero
on failure — designed for CI and non-interactive Claude Code runs. There is no separate test
framework; the harness *is* the engine test suite. To exercise a single behaviour, run the
corresponding fixture in `agents/` from the harness. `kaoz` runs a real agent (secrets from
the environment). For `kaoz --provider mlx`, run `scripts/link-mlx-metallib.sh` once after
building (the Metal library isn't produced by a plain `swift build`).

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
