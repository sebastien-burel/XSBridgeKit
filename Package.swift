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
]

let headerPaths: [CSetting] = [
    .headerSearchPath("xs/sources"),
    .headerSearchPath("xs/includes"),
    .headerSearchPath("xs/platforms"),
    .headerSearchPath("xs/tools"),
]

let package = Package(
    name: "XSBridge",
    products: [
        // Reusable Swift API consumed by host apps (e.g. TyKaoz).
        .library(name: "XSBridgeKit", targets: ["XSBridgeKit"]),
    ],
    targets: [
        // C layer: the XS engine + the bridge shim.
        .target(
            name: "XSBridge",
            // xsum.c is #included by xsMath.c, not compiled standalone.
            exclude: ["xs/sources/xsum.c"],
            cSettings: headerPaths + xsDefines,
            linkerSettings: [
                .linkedFramework("CoreServices"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Swift layer: XSEngine + HostBridge protocol + the @_cdecl callbacks.
        .target(
            name: "XSBridgeKit",
            dependencies: ["XSBridge"]
        ),
        // Test harness / demo (the 6-phase regression suite).
        .executableTarget(
            name: "xsBridgeTest",
            dependencies: ["XSBridgeKit", "XSBridge"]
        ),
    ]
)
