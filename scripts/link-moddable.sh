#!/usr/bin/env bash
#
# link-moddable.sh — wire the XS engine sources into the package as symlinks.
#
# XSBridgeKit does NOT vendor the Moddable XS sources. Instead it links the
# exact curated subset it compiles from a local Moddable checkout, found via
# the $MODDABLE environment variable. Run this once after cloning (and again
# if you move your Moddable checkout). The created links live under
# Sources/KaozJSCore/xs/ and are git-ignored. A recent Moddable master is expected.
#
# Usage:
#   export MODDABLE=/path/to/moddable
#   scripts/link-moddable.sh

set -euo pipefail

: "${MODDABLE:?Set MODDABLE to your Moddable SDK checkout (see README)}"
SRC="$MODDABLE/xs"
[ -d "$SRC/sources" ] || { echo "error: \$MODDABLE/xs/sources not found at $SRC" >&2; exit 1; }

# Resolve the package root from this script's location.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
XS="$ROOT/Sources/KaozJSCore/xs"

echo "Linking XS sources from: $SRC"
rm -rf "$XS"
mkdir -p "$XS/platforms" "$XS/tools"

# Whole-directory links (compiled .c live only in sources/). fdlibm is not
# linked: the macOS port uses the system libm (xsPlatform.h maps c_sin -> sin,
# etc.); fdlibm is only for embedded ports that redefine those.
ln -s "$SRC/sources"      "$XS/sources"
ln -s "$SRC/includes"     "$XS/includes"

# Per-file links: these directories also hold sources we must NOT compile
# (every other platform port, the xs* compilers, the YAML lib, test262, …).
# The macOS platform port (mac_xs.c) is compiled; it provides the CFRunLoop
# integration (worker-job queue + promise source) and the xsbug transport.
ln -s "$SRC/platforms/xsPlatform.h" "$XS/platforms/xsPlatform.h"
ln -s "$SRC/platforms/xsHost.h"     "$XS/platforms/xsHost.h"
ln -s "$SRC/platforms/mac_xs.c"     "$XS/platforms/mac_xs.c"

# mac_xs.h is materialized as an EDITABLE COPY (not a symlink) so the bridge can
# override the module-loader policy. XSBridge supplies its own fxFindModule /
# fxLoadModule (bridge.c) that resolve specifiers through the Swift host and hand
# back module source in memory (no archive / preload) — which requires the XS
# default loader turned OFF. This is the one spot we diverge from a pristine
# checkout; keeping it in the script (not a committed vendored file) keeps it
# reproducible and re-applied on every link.
cp "$SRC/platforms/mac_xs.h" "$XS/platforms/mac_xs.h"
sed -i '' \
  -e 's/#define mxUseDefaultFindModule 1/#define mxUseDefaultFindModule 0/' \
  -e 's/#define mxUseDefaultLoadModule 1/#define mxUseDefaultLoadModule 0/' \
  "$XS/platforms/mac_xs.h"

echo "Done. Now: swift build -c release"
