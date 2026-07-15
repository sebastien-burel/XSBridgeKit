# XSBridgeKit

A small Swift library that embeds the **XS (Moddable)** JavaScript engine and lets
JavaScript call back into **Swift** — synchronously, asynchronously, and as a
**stream** of tokens — on macOS.

You expose native capabilities by writing a tiny **C host-function target** (against the
classic `xs.h` API) that hands work to your **Swift** code; the engine runs on a private
thread, Swift work runs off it, and `await` continuations resume correctly across the
boundary without any `xsSlot` ever crossing into Swift.

```js
// in JavaScript, running inside the engine
const greeting = await host.echo("hi");      // resolved by Swift on another queue
await host.stream("prompt", t => print(t));  // Swift pushes tokens back one by one
const sum = host.add(2, 3);                   // synchronous Swift call → 5
```

The engine also loads **ES modules** from disk (`.js`/`.mjs`, and `.xsb` bytecode compiled
by `xsc`), invokes a module's `default` export as a repeatable entry point, and can
**snapshot** its whole heap to persist state across process launches.

## Install

Add the package as a local SPM dependency:

```swift
.package(path: "../XSBridgeKit"),
// ...
.target(name: "YourApp", dependencies: [
    .product(name: "XSBridgeKit", package: "XSBridgeKit"),
    "XSBridge",          // C module: flat settle functions + xsBridgePromise
    "YourHostC",         // your own C host-function target (see below)
]),
```

## How a consumer wires host functions

The bridge hardcodes **no** capabilities and installs nothing — not even `print`. A
consumer supplies a small C target (compiled with the **same XS defines** as `XSBridge`)
whose install function registers each native capability, plus the Swift side it calls.
This is the reference pattern used by the demo (`xsBridgeTestC/demoHost.c` +
`DemoHost.swift`).

**C side** — one host function per capability. An async one marshals its arguments, creates
its Promise with `xsBridgePromise`, and hands `(bridge, id, json)` to Swift:

```c
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"

extern void  myEcho(void* bridge, uint32_t id, const char* json);  // @_cdecl in Swift
extern double myAdd(double a, double b);

static void xs_echo(xsMachine* the) {           // host.echo(x) — async
    void* bridge = xsGetContext(the);
    char* json = xsBridgeArgJSON(the, 0);       // JSON.stringify(arg0), malloc'd
    uint32_t id = xsBridgePromise(the, NULL);   // xsResult = the Promise
    myEcho(bridge, id, json);
    free(json);
}
static void xs_add(xsMachine* the) {            // host.add(a,b) — synchronous
    xsResult = xsNumber(myAdd(xsToNumber(xsArg(0)), xsToNumber(xsArg(1))));
}

void MyHostInstall(void* machine) {
    xsBeginHost((xsMachine*)machine);
    xsVars(2);
    xsTry {
        xsVar(0) = xsNewObject();
        xsSet(xsGlobal, xsID("host"), xsVar(0));
        xsVar(1) = xsNewHostFunction(xs_echo, 1); xsSet(xsVar(0), xsID("echo"), xsVar(1));
        xsVar(1) = xsNewHostFunction(xs_add, 2);  xsSet(xsVar(0), xsID("add"),  xsVar(1));
    } xsCatch {}
    xsEndHost((xsMachine*)machine);
}
```

**Swift side** — `@_cdecl` counterparts. Async work runs off the XS thread and settles via
the flat `xsBridgeComplete` / `xsBridgeEmitToken` (thread-safe; they wake the engine's run
loop). Values cross the boundary as **UTF-8 JSON**:

```swift
import XSBridge   // flat C settle functions

@_cdecl("myAdd")
func myAdd(_ a: Double, _ b: Double) -> Double { a + b }

@_cdecl("myEcho")
func myEcho(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge else { return }
    let payload = json.map { String(cString: $0) } ?? "null"
    DispatchQueue.global().async {
        xsBridgeComplete(bridge, id, 1, payload)   // 1 = resolve, 0 = reject
        // xsBridgeEmitToken(bridge, id, tokenJSON) — stream a token, call stays open
    }
}
```

## Running JS

```swift
import XSBridgeKit
import XSBridgeCliC   // whatever module exposes MyHostInstall

guard let engine = XSEngine() else { fatalError("engine init failed") }
engine.withMachine { MyHostInstall($0) }        // install host functions on the XS thread

// Synchronous eval — returns the result as JSON, throws XSError on a JS throw.
let answer = try engine.eval("6 * 7")           // "42"

// Async work: kick it off, then wait for in-flight calls to settle.
try engine.eval("host.echo('hi').then(v => print(v))")
engine.runUntilIdle()

// ES modules: default export is the repeatable entry, and can take JSON params.
try engine.runModule("agent.js")                       // runs export default (…)
try engine.runModule("agent.js", params: #"{"n":5}"#)  // default(JSON.parse(params))
```

## API

| Type / member | Role |
| --- | --- |
| `XSEngine(creation:)` | Create a machine on its own dedicated thread + run loop. |
| `XSEngine(snapshot:)` | Restore a machine from snapshot bytes (fresh process). |
| `engine.eval(_:)` | Run JS synchronously on the XS thread; returns JSON, throws `XSError`. |
| `engine.runModule(_:params:)` | Import an ES module; invoke its `default` export (with optional JSON params). |
| `engine.runUntilIdle(timeout:)` | Block until all in-flight async calls settle. |
| `engine.writeSnapshot()` | Serialize the whole JS heap to `Data` (requires idle). |
| `engine.withMachine { … }` | Run C on the XS thread with the opaque machine handle (install hook). |
| `engine.pendingCount` | Number of in-flight async calls. |
| `XSCreation` | VM sizing (heap/stack/key counts) with validated defaults. |
| `XSError` | A JS error surfaced to Swift as a message (never a crash). |
| `xsBridgePromise` / `xsBridgeArgJSON` (C, `bridgeXS.h`) | Create an async call's Promise / stringify an argument. |
| `xsBridgeComplete` / `xsBridgeEmitToken` (C, `bridge.h`) | Settle / stream an async call from any thread. |

## Snapshots (persist / restore)

`writeSnapshot()` serializes the entire machine; `XSEngine(snapshot:)` rebuilds it in a
fresh process — fast startup plus state persistence across launches. Because host C
functions are referenced in the heap by index, register a **frozen, append-only** host
table once (`xsBridgeRegisterHostTable`); each snapshot carries its ordered name list and a
restore accepts a prefix-compatible superset (append safe, reorder/removal rejected). Write
requires the engine to be idle (`pendingCount == 0`).

The `xsBridgeCli` sandbox exposes it:

```sh
swift run -c release xsBridgeCli --snapshot vm.xsbk init.js   # run, then write vm.xsbk
swift run -c release xsBridgeCli --restore vm.xsbk act.js     # restore (new process), run
swift run -c release xsBridgeCli --restore vm.xsbk --snapshot vm.xsbk act.js  # persist a session
```

## Invariants

1. **No XS exception crosses a Swift frame.** A JS error becomes a clean `XSError`.
2. **No `xsSlot` crosses into Swift.** Swift only ever sees opaque ids and UTF-8 JSON.
3. **Single-threaded XS.** All machine access happens on one dedicated thread/run loop;
   Swift work runs off it and returns only via the run-loop signal.
4. **Systematic rooting.** `resolve`/`reject`/`onToken` are remembered on intake and
   forgotten exactly once at settle (remember/forget counters balance when idle).

See [`CLAUDE.md`](CLAUDE.md) for the full architecture, the rooting rules, and the snapshot
callback-table details.

## Moddable SDK (required)

The XS engine sources are **not vendored** in this repository. They are linked from a local
Moddable checkout, so you need one before building (a recent `master` is expected).

```sh
# 1. Get Moddable (shallow clone is fine)
git clone --depth 1 https://github.com/Moddable-OpenSource/moddable.git

# 2. Point $MODDABLE at it and link the sources into the package
export MODDABLE="$PWD/moddable"
./scripts/link-moddable.sh
```

`scripts/link-moddable.sh` symlinks the curated subset the package compiles (`xs/sources`,
`xs/includes`, the platform dispatch headers `xsPlatform.h`/`xsHost.h`, and the macOS port
`mac_xs.c`), and materializes an editable copy of `mac_xs.h` (with the default module
loaders turned off, since the bridge supplies its own). Those links are local-only and
git-ignored. Build flags live in `Package.swift`; the engine itself is not built separately
— only its sources are compiled into this package.

## Build & run

`xsBridgeTest` is a CLI harness whose demo host (echo / stream / fail / add) doubles as the
regression suite; `xsBridgeCli` is a sandbox for running JS files and modules:

```sh
swift build -c release
swift run -c release xsBridgeTest        # 6-phase suite; exits non-zero if any check fails
swift run -c release xsBridgeCli file.js # run a JS file as an ES module
```

## License

Original project code is under the [MIT License](LICENSE). It links against the Moddable
XS engine, which is under the GNU LGPL v3 and is **not** redistributed here — you supply it
via your own Moddable checkout. See [`NOTICE`](NOTICE) for details.
