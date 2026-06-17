#!/usr/bin/env bash
#
# link-moddable.sh — wire the XS engine sources into the package as symlinks.
#
# XSBridgeKit does NOT vendor the Moddable XS sources. Instead it links the
# exact curated subset it compiles from a local Moddable checkout, found via
# the $MODDABLE environment variable. Run this once after cloning (and again
# if you move your Moddable checkout). The created links live under
# Sources/XSBridge/xs/ and are git-ignored. A recent Moddable master is expected.
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
XS="$ROOT/Sources/XSBridge/xs"

echo "Linking XS sources from: $SRC"
rm -rf "$XS"
mkdir -p "$XS/platforms" "$XS/tools"

# Whole-directory links (compiled .c live only in sources/ and tools/fdlibm/).
ln -s "$SRC/sources"      "$XS/sources"
ln -s "$SRC/includes"     "$XS/includes"
ln -s "$SRC/tools/fdlibm" "$XS/tools/fdlibm"

# Per-file links: these directories also hold sources we must NOT compile
# (every other platform port, the xs* compilers, the YAML lib, test262, …).
ln -s "$SRC/platforms/xsHost.h"    "$XS/platforms/xsHost.h"
ln -s "$SRC/platforms/xsPlatform.h" "$XS/platforms/xsPlatform.h"
ln -s "$SRC/tools/xst.h"           "$XS/tools/xst.h"

echo "Done. Now: swift build -c release"
