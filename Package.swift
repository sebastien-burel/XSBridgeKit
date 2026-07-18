// swift-tools-version:5.9
import PackageDescription

// Compile flags derived from $MODDABLE/xs/makefiles/mac (xst target).
// These MUST be identical across every translation unit in XSBridge: the
// txMachine struct layout depends on them, so a mismatch is silent ABI corruption.
let xsDefines: [CSetting] = [
  .define("XS_ARCHIVE", to: "1"),
  .define("INCLUDE_XSPLATFORM", to: "1"),
  .define("XSPLATFORM", to: "\"mac_xs.h\""),
  .define("mxDebug", to: "1"),
  .define("mxStringInfoCacheLength", to: "4"),
  // Snapshot-clean engine: fxStringX copies into the heap (no external string
  // values) and chunk layout is deterministic — required by fxWriteSnapshot.
  // ABI-affecting (txChunk layout), so it MUST be identical across all C targets.
  .define("mxSnapshot", to: "1"),
]

// Header search paths are relative to each target's directory, so consumer C
// targets (host functions) reach the XS tree through the ../XSBridge prefix.
let xsHeaderDirs = ["xs/sources", "xs/includes", "xs/platforms", "xs/tools"]
let headerPaths: [CSetting] = xsHeaderDirs.map { .headerSearchPath($0) }
let consumerHeaderPaths: [CSetting] = xsHeaderDirs.map { .headerSearchPath("../XSBridge/" + $0) }

let package = Package(
    name: "XSBridge",
    products: [
        // Reusable Swift API consumed by host apps (e.g. TyKaoz).
        .library(name: "XSBridgeKit", targets: ["XSBridgeKit"]),
        // The flat C bridge (bridge.h: xsServicePromise, settle functions, the XS
        // headers). Exposed so a consumer can build its own C host-function
        // target and call the settle functions from @_cdecl Swift.
        .library(name: "XSBridge", targets: ["XSBridge"]),
    ],
    targets: [
        // C layer: the XS engine + the bridge shim.
        .target(
            name: "XSBridge",
            // xsum.c is #included by xsMath.c, not compiled standalone.
            // xsffi.c implements the xsmc C API + mod syscall shims; nothing in
            // this build references it (we use the classic xs.h API), so it is
            // dead code — exclude it.
            exclude: ["xs/sources/xsum.c", "xs/sources/xsffi.c"],
            cSettings: headerPaths + xsDefines,
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Swift layer: XSEngine (dedicated thread + CFRunLoop per machine).
        .target(
            name: "XSBridgeKit",
            dependencies: ["XSBridge"]
        ),
        // C side of the demo host: host.echo/stream/fail/add written against
        // xs.h. Same defines as XSBridge — the txMachine ABI depends on them.
        .target(
            name: "xsBridgeTestC",
            // XSBridge dependency exposes its public headers (bridge.h).
            dependencies: ["XSBridge"],
            cSettings: consumerHeaderPaths + xsDefines
        ),
        // Test harness / demo (the multi-phase regression suite).
        .executableTarget(
            name: "xsBridgeTest",
            dependencies: ["XSBridgeKit", "XSBridge", "xsBridgeTestC"]
        ),
    ]
)
