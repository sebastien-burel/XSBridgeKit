# KaozKit

A Swift package for **autonomous LLM agents written in JavaScript**, running on an embedded
**XS (Moddable)** engine. An agent is a small JS module — `export function run(input)` — that
drives a language model, calls tools, and reads/writes memory through a `host.*` surface;
the engine runs on a private thread, the LLM/tool/memory work runs in Swift off it, and
`await` continuations resume correctly across the boundary without any `xsSlot` ever
crossing into Swift.

```js
// agent.js — runs inside the engine
export async function run(input) {
  const reply = await host.llm.chat(
    [{ role: "user", content: input.question }],
    { tools: ["current_datetime", "web_search"] }   // the model may call these
  );
  await host.memory.save("last question", input.question);
  return { answer: reply };
}
```

```sh
export ANTHROPIC_API_KEY=…
swift run -c release kaoz agent.js --provider anthropic --model claude-fable-5 \
    --input '{"question":"what day is it?"}'
```

## One package, layered products

KaozKit is a single SwiftPM package that vends products in layers. A project embedding
**only JavaScript** depends on `KaozJS`; an **agent** project depends on `KaozKit`, which
pulls the engine in.

```
KaozJSCore (C)  — XS engine + the xsService* async-settle bridge
KaozJS          — Swift XSEngine (dedicated thread + CFRunLoop, snapshot, module roots)
KaozHostC (C)   — the agent's XS host functions (host.llm/tool/memory/schedule)
KaozKit         — agent runtime: providers, tools, memory, channels, persona
KaozMLX         — MLX local-inference providers (heavy deps, opt-in)
kaoz            — headless CLI / resident daemon
```

`import KaozKit` for the agent runtime; `import KaozJS` (+ `KaozJSCore`) for the bare
JS↔Swift engine. **macOS 26+, Apple Silicon.**

```swift
.package(path: "../KaozKit"),
// agent runtime:
.target(name: "YourApp", dependencies: [
    .product(name: "KaozKit", package: "KaozKit"),
    .product(name: "KaozMLX", package: "KaozKit"),   // optional: on-device MLX
]),
// …or just the JS engine:
.target(name: "YourEngine", dependencies: [
    .product(name: "KaozJS", package: "KaozKit"),
    .product(name: "KaozJSCore", package: "KaozKit"),   // flat C settle functions
]),
```

## Writing an agent (JS)

An agent module exports `run(input)` (or `default`). Its return value comes back to Swift as
JSON. The `host` global (installed by `KaozHostC`) is the whole capability surface:

| `host.*` | Role |
| --- | --- |
| `host.llm.chat(messages, { tools }, onToken?)` | One LLM turn on the run's default provider. Runs the tool-call loop internally (the model calls a tool → Swift executes it → the model continues), resolves with the final assistant text. `onToken` streams text deltas. |
| `host.provider(id, { model, … }).chat(…)` | Same, on a specific provider from the catalog. Secrets stay in Swift — never passed from JS. |
| `host.providers()` | The provider ids/names the host exposes. |
| `host.tool.list()` / `host.tool.call(name, args)` | Enumerate / invoke a registered tool directly. |
| `host.memory.save(title, content)` / `.read(id)` / `.list()` / `.search(query, limit?)` | Persistent notes; `search` ranks by embedding similarity. |
| `host.schedule(ms, payload?)` / `host.every(ms, payload?)` / `host.cancel(handle)` | Self-scheduling: deliver a `tick` to the agent's `onTick` after / every `ms` (resident mode). |
| `host.usage()` | Cumulative `{ promptTokens, completionTokens, chatCalls }` for the run. |
| `host.log(…args)` | Log to the host. |

`messages` are `{ role, content }` objects (`role`: `system` / `user` / `assistant`);
`tools` is an array of registered tool **names**. A **resident** agent instead exports an
object of handlers — `{ onMessage, onEvent, onTick }` — and its JS heap (state, conversation)
survives across deliveries.

An agent may spawn **sub-agents** from the script: `new Thread(name)` + `new Service(thread,
"sub-agent")`, then `await svc.method(args)` (see the engine layer below).

## Running an agent (Swift)

Two entry points in `KaozKit`:

**`AgentRuntime`** — one-shot. One engine per run, torn down when `run` finishes.

```swift
import KaozKit

let runtime = AgentRuntime(
    makeProvider: { AnthropicProvider(apiKey: key, model: "claude-fable-5") },
    tools: ToolRegistry(tools: [SaveMemoryTool(store: memory), /* … */]),
    memory: memory,                    // any MemoryStoring (e.g. SemanticMemoryStore)
    persona: "You are Kaoz, terse and precise.")

let json = try await runtime.run(script: source, input: ["question": "…"], timeout: 30)
// …or Moddable-style, importing the agent + its modules from disk by bare name:
let json2 = try await runtime.runRooted(
    entryModule: "agent", roots: [("", agentDir.path)], input: nil, timeout: 30)
```

**`AgentHost`** — resident. One engine kept alive across many `deliver(kind:payload:)`
calls; the JS heap persists, and the whole heap can be snapshotted to disk and restored in a
fresh process.

```swift
let agent = AgentHost(entryModule: "agent", roots: [("", dir.path)],
                      makeProvider: …, tools: registry, memory: memory,
                      installThreads: false)          // false ⇒ snapshot-capable
let out  = try await agent.deliver(kind: "message", payload: ["text": "hi"])
let bytes = try agent.writeSnapshot()                 // persist state
// …later, fresh process:
let restored = AgentHost(snapshot: bytes, roots: […], makeProvider: …, tools: …, memory: …)
```

Both take a `makeProvider` (the run default), an optional `resolveProvider(id, options)` (for
JS-selected providers, secrets injected in Swift), a `ProviderDescriptor` catalog, a
`ToolRegistry`, a `MemoryStoring`, and optional `tokenBudget` / `persona`. `Sources/kaoz/
main.swift` is the canonical worked example of wiring all of them.

## Providers

Every provider conforms to `LLMProvider` (a streaming `chat(messages:tools:)`).

- **Native (Swift):** `AnthropicProvider`, `GoogleProvider` (Gemini), `OllamaProvider`,
  `OpenAIProvider`, and OpenAI-compatible wrappers `LocalOpenAIProvider` (LM Studio /
  llama.cpp), `DeepSeekProvider`, `MistralProvider`, `QwenProvider`, `ZAIProvider`;
  `AppleIntelligenceProvider` (on-device Foundation Models); `ComfyUIProvider` (image
  generation).
- **JS-defined** (`JSProvider`, backed by `Resources/js/*.js` over the native `__http`
  primitive): `JSProviders.anthropic` / `.openai` / `.openaiCompatible` / `.ollama` /
  `.kimi` / `.google`.
- **Embeddings** (`EmbeddingProvider`): `HashingEmbeddingProvider` (dependency-free,
  lexical) and `OllamaEmbeddingProvider`; MLX embeddings via `KaozMLX`.

**KaozMLX** (opt-in) adds on-device Apple-silicon inference: `MLXLLMProvider`,
`MLXEmbeddingProvider`, plus `MLXModelStore` / `MLXDownloadCenter` / `ModelCatalogService`
for Hugging Face model management. Its Metal library isn't produced by `swift build` for a
CLI, so run `scripts/link-mlx-metallib.sh` once after building to use `--provider mlx` from
`kaoz` (see the script header).

## Tools & confinement

Tools conform to `Tool` and register in a `ToolRegistry`. Read tools are safe by default;
actuation is opt-in and confined.

- **Read:** `ReadFileTool`, `ListDirectoryTool`, `GrepFilesTool` (each confined to
  `AuthorizedRoot` folders), `CurrentLocationTool`, memory tools; JS tools `current_datetime`,
  `fetch_url`, `web_search` (Brave).
- **Actuation (opt-in):** `WriteFileTool` / `EditFileTool` (confined to explicitly authorized
  write roots — a separate grant from read access), `ShellTool` (a fixed working directory),
  `HTTPRequestTool` (optional host allow-list).
- **Email:** `SendEmailTool` / `ReadEmailTool` over local IMAP/SMTP (Proton Bridge).
- **Plugins:** `HTTPPluginTool` builds tools from a declarative `PluginManifest` +
  `PluginSecrets`.
- **Memory:** `SemanticMemoryStore` (embedding-ranked recall) behind the `MemoryStoring` /
  `MemoryRetrieving` protocols.
- **Channels:** `WebhookServer` delivers inbound HTTP request bodies to a resident agent and
  replies with its result.

## CLI — `kaoz`

`kaoz <agent.js> [flags]` runs a standalone agent headless. Config (secrets, model) comes
from the environment; the result is printed to stdout as JSON, errors to stderr with a
non-zero exit.

| Flag | Effect |
| --- | --- |
| `--provider` | `anthropic` · `js-anthropic` · `js-openai` · `js-ollama` · `js-google` · `js-kimi` · `local` · `apple` · `mlx` (default `anthropic`) |
| `--model M` / `--input JSON` / `--timeout SEC` | model, agent input, per-run budget |
| `--library DIR` / `--modules nom=dir` | extra module roots (the agent's own dir is always a root; resolution is confined) |
| `--root DIR` | authorize a folder for the read file-tools |
| `--allow-write DIR` / `--allow-shell [--shell-dir DIR]` / `--allow-http [--http-host H]` | opt-in actuation |
| `--email` | enable `send_email` / `read_email` (Proton Bridge) |
| `--persona FILE` / `--budget TOKENS` | base identity prepended to every chat; hard token cap |
| `--resident [--daemon] [--state FILE]` | keep one engine alive; deliver a JSON message per stdin line; `--daemon` keeps scheduled ticks firing; `--state` snapshots the JS heap across processes |
| `--webhook PORT` | inbound HTTP → resident agent (implies resident + daemon) |
| `--embed-ollama MODEL` | use a real embedding model for `memory.search` |

Secrets are read from the environment: `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`GOOGLE_API_KEY`, `MOONSHOT_API_KEY`/`KIMI_API_KEY`, `TYKAOZ_LOCAL_BASE_URL`, `BRAVE_API_KEY`
(enables `web_search`), `PROTON_BRIDGE_*` (email), `TYKAOZ_MODEL`, `TYKAOZ_MEMORY_FILE`.

## The engine layer (KaozJS)

Under the agent runtime is a general-purpose JS↔Swift bridge, usable on its own. You expose
native capabilities by writing a small **C host-function target** (against the classic
`xs.h` API) that hands work to your Swift code; the engine runs on a private thread, Swift
work runs off it, and `await` continuations resume across the boundary. This is exactly how
`KaozHostC` + `TyKaozHost.swift` implement the agent's `host.*` surface — the demo pair
`KaozJSTestC/demoHost.c` + `KaozJSTests/DemoHost.swift` (echo / stream / fail / add, plus a
multi-machine service phase) is the reference pattern and doubles as the regression suite.

```c
#include "xs.h"
#include "bridge.h"
#include "bridgeXS.h"

extern void myEcho(void* bridge, uint32_t id, const char* json);  // @_cdecl in Swift

static void xs_echo(xsMachine* the) {           // host.echo(x) — async
    void* bridge = xsGetContext(the);
    char* json = xsBridgeArgJSON(the, 0);       // JSON.stringify(arg0), malloc'd
    uint32_t id = xsServicePromise(the, NULL);  // xsResult = the Promise
    myEcho(bridge, id, json);
    free(json);
}
```

```swift
import KaozJSCore   // flat C settle functions

@_cdecl("myEcho")
func myEcho(_ bridge: UnsafeMutableRawPointer?, _ id: UInt32, _ json: UnsafePointer<CChar>?) {
    guard let bridge else { return }
    let payload = json.map { String(cString: $0) } ?? "null"
    DispatchQueue.global().async {
        xsServiceResolve(bridge, id, payload)     // or xsServiceReject / xsServiceEmit
    }
}
```

```swift
import KaozJS
import YourHostC

guard let engine = XSEngine() else { fatalError() }
engine.withMachine { MyHostInstall($0) }          // install on the XS thread
let answer = try engine.eval("6 * 7")             // "42"
try engine.runModule("agent.js")                  // runs export default
```

Core `KaozJS` API: `XSEngine` (`eval`, `runModule`, `runUntilIdle`, `withMachine`,
`installThreads`, `writeSnapshot`, `pendingCount`; `init(snapshot:)`), `XSCreation`,
`XSError`. The engine also **snapshots** its whole heap (persist/restore across launches),
runs **multi-machine services** (JS-to-JS `Thread` / `Service` calls, values alien-marshalled),
and confines module resolution to registered **roots**. See [`CLAUDE.md`](CLAUDE.md) for the
rooting rules, the snapshot callback-table, and the settle-path internals.

## Setup — Moddable SDK (required)

The XS engine sources are **not vendored**; they are linked from a local Moddable checkout
(a recent `master`), so you need one before building.

```sh
git clone --depth 1 https://github.com/Moddable-OpenSource/moddable.git
export MODDABLE="$PWD/moddable"
./scripts/link-moddable.sh          # symlinks the XS subset into Sources/KaozJSCore/xs/
```

`link-moddable.sh` symlinks the curated subset the package compiles (`xs/sources`,
`xs/includes`, the platform dispatch headers, and the macOS port `mac_xs.c`) and materializes
an editable copy of `mac_xs.h` with the default module loaders turned off (the bridge supplies
its own). Those links are git-ignored.

## Build & run

```sh
swift build -c release
swift run -c release KaozJSTests        # engine regression suite; non-zero exit on any failure
swift run -c release kaoz agent.js --provider anthropic --input '{"question":"…"}'
```

`KaozJSTests` is a multi-phase CLI harness whose demo host doubles as the engine regression
suite; the JS fixtures it drives live in `agents/`.

## License

Original project code is under the [MIT License](LICENSE). It links against the Moddable XS
engine, which is under the GNU LGPL v3 and is **not** redistributed here — you supply it via
your own Moddable checkout. See [`NOTICE`](NOTICE) for details.
