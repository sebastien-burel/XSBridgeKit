// swift-tools-version:5.9
import PackageDescription

// KaozKit — one package, layered products: embed the XS (Moddable) JavaScript
// engine in Swift (KaozJSCore + KaozJS) and, on top of it, a runtime for
// autonomous LLM agents (KaozKit). A project that only wants to embed JS depends
// on `KaozJS`; an agent project depends on `KaozKit` (which pulls the engine in).
//
//   KaozJSCore (C)  — XS engine + the xsService* async-settle bridge
//   KaozJS          — Swift XSEngine (dedicated thread + CFRunLoop, snapshot, roots)
//   KaozHostC (C)   — the agent's XS host functions
//   KaozKit         — agent runtime: providers, tools, memory, channels, persona
//   KaozMLX         — MLX local-inference providers (heavy deps, opt-in)
//   kaoz            — headless CLI / resident daemon

// XS compile flags derived from $MODDABLE/xs/makefiles/mac. These MUST be
// identical across every C translation unit: the txMachine/txChunk struct layout
// depends on them, so a mismatch is silent ABI corruption. Defined ONCE here.
let xsDefines: [CSetting] = [
  .define("XS_ARCHIVE", to: "1"),
  .define("INCLUDE_XSPLATFORM", to: "1"),
  .define("XSPLATFORM", to: "\"mac_xs.h\""),
  .define("mxDebug", to: "1"),
  .define("mxStringInfoCacheLength", to: "4"),
  // Snapshot-clean engine (fxStringX copies into the heap, deterministic chunk
  // layout) — required by fxWriteSnapshot. ABI-affecting (txChunk layout).
  .define("mxSnapshot", to: "1"),
  // Silence XS's own stdout traces; real errors already surface to Swift.
  .define("mxNoConsole", to: "1"),
]

// Header search paths are relative to each target's directory. The XS engine
// sources live under KaozJSCore/xs/ (symlinked from $MODDABLE by
// scripts/link-moddable.sh); the two C consumer targets reach them through the
// ../KaozJSCore prefix (in-package, so no vendor/ symlinks are needed).
let xsDirs = ["xs/sources", "xs/includes", "xs/platforms", "xs/tools"]
let corePaths: [CSetting] = xsDirs.map { .headerSearchPath($0) }
let hostPaths: [CSetting] =
  xsDirs.map { .headerSearchPath("../KaozJSCore/" + $0) }
  + [.headerSearchPath("../KaozJSCore/include")]
let testPaths: [CSetting] = xsDirs.map { .headerSearchPath("../KaozJSCore/" + $0) }

let package = Package(
    name: "KaozKit",
    platforms: [.macOS("26.0")],
    products: [
        // Agent runtime — the flagship. `import KaozKit`.
        .library(name: "KaozKit", targets: ["KaozKit"]),
        // Generic JS↔Swift engine bridge, reusable without any agent stack.
        .library(name: "KaozJS", targets: ["KaozJS"]),
        // The flat C bridge (bridge.h: xsServicePromise, settle functions, the XS
        // headers) — exposed so a consumer can build its own C host-function
        // target and call the settle functions from @_cdecl Swift.
        .library(name: "KaozJSCore", targets: ["KaozJSCore"]),
        // MLX local-inference providers, isolated so the base library and the
        // headless CLI can opt out of the heavy MLX / transformers dependencies.
        .library(name: "KaozMLX", targets: ["KaozMLX"]),
        // Headless runner / resident daemon for autonomous JS agents.
        .executable(name: "kaoz", targets: ["kaoz"]),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.31.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.31.3"),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.3"),
    ],
    targets: [
        // C layer: the XS engine + the bridge shim.
        .target(
            name: "KaozJSCore",
            // xsum.c is #included by xsMath.c, not compiled standalone.
            // xsffi.c implements the xsmc C API (unused here) — dead code.
            exclude: ["xs/sources/xsum.c", "xs/sources/xsffi.c"],
            cSettings: corePaths + xsDefines,
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Swift layer: XSEngine (dedicated thread + CFRunLoop per machine).
        .target(
            name: "KaozJS",
            dependencies: ["KaozJSCore"]
        ),
        // The agent's XS host functions (echo/stream, LLM chat, tools, memory,
        // schedule, http…). Reaches the XS headers through ../KaozJSCore.
        .target(
            name: "KaozHostC",
            dependencies: ["KaozJSCore"],
            cSettings: hostPaths + xsDefines
        ),
        // The reusable agent runtime: agent host, LLM providers, tools, memory,
        // channels, persona. JS-first runtime code lives as ES modules loaded at
        // run time from the bundle (Bundle.module) — see Resources/js/.
        .target(
            name: "KaozKit",
            dependencies: ["KaozJS", "KaozJSCore", "KaozHostC"],
            resources: [.copy("Resources/js")],
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
            ]
        ),
        // MLX local-inference providers + on-device model management. Heavy deps
        // live here only, behind the KaozMLX product, so plain KaozKit consumers
        // don't pull them in.
        .target(
            name: "KaozMLX",
            dependencies: [
                "KaozKit",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXVLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ]
        ),
        // Headless runner. Depends on KaozMLX so it can run MLX (and Apple
        // Intelligence) providers too.
        .executableTarget(
            name: "kaoz",
            dependencies: ["KaozKit", "KaozMLX"]
        ),
        // C side of the engine's demo host: host.echo/stream/fail/add written
        // against xs.h. Same defines as KaozJSCore — the txMachine ABI needs them.
        .target(
            name: "KaozJSTestC",
            dependencies: ["KaozJSCore"],
            cSettings: testPaths + xsDefines
        ),
        // The engine regression suite (multi-phase harness / demo).
        .executableTarget(
            name: "KaozJSTests",
            dependencies: ["KaozJS", "KaozJSCore", "KaozJSTestC"]
        ),
    ]
)
