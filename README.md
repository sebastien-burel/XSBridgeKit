# XSBridgeKit

A small Swift library that embeds the **XS (Moddable)** JavaScript engine and lets
JavaScript call back into **Swift** — synchronously, asynchronously, and as a
**stream** of tokens — on macOS.

You implement a `HostBridge` in Swift that exposes whatever capabilities you want;
the bridge surfaces them to JS as ordinary `host.*` functions. JS runs on a private
thread, Swift work runs off it, and `await` continuations resume correctly across the
boundary without any `xsSlot` ever crossing into Swift.

```js
// in JavaScript, running inside the engine
const greeting = await host.echo("hi");      // resolved by Swift on another queue
await host.stream("prompt", t => print(t));  // Swift pushes tokens back one by one
const sum = host.add(2, 3);                   // synchronous Swift call → 5
```

## Install

Add the package as a local SPM dependency and import the library target:

```swift
.package(path: "../XSBridgeKit"),
// ...
.target(name: "YourApp", dependencies: [
    .product(name: "XSBridgeKit", package: "XSBridgeKit"),
]),
```

```swift
import XSBridgeKit
```

## Usage

A consumer does two things: implement `HostBridge`, and supply a JS `prelude` that
defines the ergonomic `host.*` wrappers around the generic primitives `__nativeCall`
(async) and `__nativeCallSync` (sync). Keys, parameters and results cross the boundary
as **UTF-8 JSON**.

```swift
import XSBridgeKit
import Foundation

final class MyHost: HostBridge {
    // JS run once at engine creation; defines the host.* API.
    var prelude: String {
        """
        host.echo = (x) => new Promise((res, rej) => __nativeCall('echo', [x], res, rej));
        host.add  = (a, b) => __nativeCallSync('add', [a, b]);
        """
    }

    // Async call: do work off the engine's thread, then settle via the responder.
    func handle(key: String, paramsJSON: String, responder: HostResponder) {
        DispatchQueue.global().async {
            responder.resolve(paramsJSON)   // echo back the JSON array's value, etc.
            // responder.emit(json)  — stream a token, call stays open
            // responder.reject(json) — settle as a rejected promise
        }
    }

    // Synchronous call: return a JSON result immediately.
    func handleSync(key: String, paramsJSON: String) -> String {
        // parse paramsJSON, compute, return JSON
        return "5"
    }
}

guard let engine = XSEngine(host: MyHost()) else { fatalError("engine init failed") }

// Synchronous eval — returns the result as JSON, throws XSError on a JS throw.
let answer = try engine.eval("6 * 7")        // "42"

// Async work: kick it off, then wait for in-flight calls to settle.
try engine.eval("host.echo('hi').then(v => print(v))")
engine.runUntilIdle()
print(engine.outputs)                        // ["hi"]
```

## API

| Type / member | Role |
| --- | --- |
| `XSEngine(host:)` | Creates a machine on its own dedicated thread + run loop. |
| `engine.eval(_:)` | Run JS synchronously on the XS thread; returns JSON, throws `XSError`. |
| `engine.runUntilIdle(timeout:)` | Block until all in-flight async calls settle. |
| `engine.outputs` | Values passed to JS `print()`, in order. |
| `HostBridge` | Protocol you implement: `prelude`, `handle`, `handleSync`. |
| `HostResponder` | Settles an async call: `resolve` / `reject` / `emit` (stream). Thread-safe. |
| `XSError` | A JS error surfaced to Swift as a message (never a crash). |

## How it works (invariants)

The async path creates the `Promise` **on the JS side**; `__nativeCall` roots
`resolve`/`reject` (and `onToken` for streams) in C, marshals params to JSON, and
hands `(id, key, json)` to your `HostBridge`. Your Swift work runs off the engine's
run loop and signals back via a `CFRunLoopSource`; the engine's thread then settles
the promise and drains promise jobs to resume the `await`. Three rules hold throughout:

1. **No XS exception crosses a Swift frame.** A JS error becomes a clean `XSError`.
2. **No `xsSlot` crosses into Swift.** Swift only ever sees opaque ids and JSON.
3. **Single-threaded XS.** All machine access happens on one dedicated thread/run loop;
   Swift work runs off it and returns only via the run-loop signal.

See [`CLAUDE.md`](CLAUDE.md) for the full architecture and the rooting rules.

## Moddable SDK (required)

The XS engine sources are **not vendored** in this repository. They are linked from a
local Moddable checkout, so you need one before building (a recent `master` is expected).

```sh
# 1. Get Moddable (shallow clone is fine)
git clone --depth 1 https://github.com/Moddable-OpenSource/moddable.git

# 2. Point $MODDABLE at it and link the sources into the package
export MODDABLE="$PWD/moddable"
./scripts/link-moddable.sh
```

`scripts/link-moddable.sh` symlinks the exact curated subset the package compiles
(`xs/sources`, `xs/includes`, the two macOS platform headers, `xs/tools/xst.h` and
`xs/tools/fdlibm`) into `Sources/XSBridge/xs/`. Those links are local-only and
git-ignored. The build configuration (compile flags from the `xst` mac makefile) lives
in `Package.swift`. The engine itself does **not** need to be built — only its sources
are compiled into this package.

## Build & run the demo

`xsBridgeTest` is a CLI harness whose `DemoHost` (echo / stream / fail / add) doubles
as the regression suite:

```sh
swift build -c release
swift run -c release xsBridgeTest    # exits non-zero if any check fails
```

## License

Original project code is under the [MIT License](LICENSE). It links against the Moddable
XS engine, which is under the GNU LGPL v3 and is **not** redistributed here — you supply
it via your own Moddable checkout. See [`NOTICE`](NOTICE) for details.
