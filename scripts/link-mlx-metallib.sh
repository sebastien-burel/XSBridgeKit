#!/usr/bin/env bash
#
# link-mlx-metallib.sh — make `swift run TyKaozCli … --provider mlx` work.
#
# mlx-swift compiles its Metal shader library (default.metallib, inside
# mlx-swift_Cmlx.bundle) only in an Xcode build — not in a plain `swift build`.
# A SwiftPM command-line executable therefore fails at runtime with
# "Failed to load the default metallib". MLX searches for the library colocated
# with the binary and in the `mlx-swift_Cmlx` bundle, so this copies the bundle
# produced by the app's Xcode build next to TyKaozCli's build products.
#
# Run once after each `swift build` (of TyKaozCli). Requires the TyKaoz app to
# have been built in Xcode at least once (that build produces the metallib).
#
set -euo pipefail

pkg_dir="$(cd "$(dirname "$0")/.." && pwd)"     # TyKaozKit/
bundle="mlx-swift_Cmlx.bundle"
metallib_rel="Contents/Resources/default.metallib"

echo "Looking for $bundle (with default.metallib)…"

# Candidate sources: the app's Xcode build products (sibling ../TyKaoz), then a
# broad sweep of DerivedData. Pick the first that actually holds the metallib.
src=""
while IFS= read -r cand; do
    [ -f "$cand/$metallib_rel" ] || continue
    src="$cand"
    break
done < <(
    ls -dt "$pkg_dir/../TyKaoz/Build/Products/"*"/$bundle" 2>/dev/null || true
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 -type d -name "$bundle" 2>/dev/null || true
)

if [ -z "$src" ]; then
    echo "error: could not find $bundle with a built default.metallib." >&2
    echo "       Build the TyKaoz app in Xcode once, then re-run this." >&2
    exit 1
fi
echo "source: $src"

# Copy the bundle + a colocated copy of the metallib into each build config dir.
linked=0
for cfg in release debug; do
    out="$pkg_dir/.build/$cfg"
    [ -d "$out" ] || continue
    rm -rf "$out/$bundle"
    cp -R "$src" "$out/"
    cp "$src/$metallib_rel" "$out/default.metallib"
    echo "linked → $out/"
    linked=1
done

if [ "$linked" -eq 0 ]; then
    echo "error: no .build/release or .build/debug — run 'swift build' first." >&2
    exit 1
fi

echo "done — TyKaozCli can now run --provider mlx."
