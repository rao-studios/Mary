#!/bin/bash
# Compile Frigate's vendored MLX Metal shaders into mlx.metallib, next to the
# built binary.
#
#   ./scripts/build-metallib.sh [debug|release]     (default: debug)
#
# Override Frigate's location with FRIGATE_DIR=/path/to/Frigate.
#
# WHY THIS SCRIPT EXISTS AT ALL. `swift build` cannot compile Metal. Xcode's
# package support can — it turns a target's `.metal` sources into a
# `default.metallib` inside `Frigate_Cmlx.bundle` — but the SwiftPM command
# line has no Metal compiler step of any kind, so every binary in `.build`
# ships without the shaders MLX needs to run on the GPU. The failure is at
# RUNTIME and reads:
#
#   MLX error: Failed to load the default metallib. library not found
#   library not found library not found library not found
#
# — four "library not found"s because `load_default_library` in
# `mlx/backend/metal/device.cpp` tries four places and reports them all.
#
# WHERE MLX LOOKS, in its own order:
#   1. <binary dir>/mlx.metallib          ← what this script writes
#   2. <binary dir>/Resources/mlx.metallib
#   3. default.metallib in a loaded SwiftPM bundle (needs SWIFTPM_BUNDLE)
#   4. <binary dir>/Resources/default.metallib
#   5. METAL_PATH, a compile-time constant — "default.metallib", relative,
#      so it resolves against the working directory and almost never hits
#
# The first rung is the one worth targeting: it depends on the binary's own
# location rather than on bundle loading or the working directory. Note that
# Frigate defines SWIFTPM_BUNDLE as "mlx-swift_Cmlx" — a name inherited from
# upstream that no longer matches anything, since SwiftPM would name the
# bundle after ITS package, `Frigate_Cmlx`. Rung 3 is not a road out of this.
#
# RUN IT AFTER `swift build`, before running anything that touches the local
# engine. `scripts/dev.sh` and `scripts/make-app.sh` both call it.

set -e

CONFIG="${1:-debug}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FRIGATE_DIR="${FRIGATE_DIR:-$REPO_ROOT/../Frigate}"
MLX_METAL_DIR="$FRIGATE_DIR/Sources/Cmlx/mlx-generated/metal"
BINARY_DIR="$REPO_ROOT/.build/$CONFIG"
METALLIB_OUT="$BINARY_DIR/mlx.metallib"

if [ ! -d "$MLX_METAL_DIR" ]; then
    echo "build-metallib: no MLX metal shaders at $MLX_METAL_DIR"
    echo "  Set FRIGATE_DIR, or run 'swift build' first to resolve dependencies."
    exit 1
fi

mkdir -p "$BINARY_DIR"

# SKIP WHEN IT IS ALREADY CURRENT. Three callers invoke this and the compile
# is ~50 files; re-running it on every launch would make `dev.sh` feel broken.
# `find -newer` asks the only question that matters: did any shader change
# after the library was written.
if [ -f "$METALLIB_OUT" ] \
   && [ -z "$(find "$MLX_METAL_DIR" -name '*.metal' -newer "$METALLIB_OUT" -print -quit)" ]; then
    echo "build-metallib: $METALLIB_OUT is current"
    exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "build-metallib: compiling shaders from $MLX_METAL_DIR"

AIR_FILES=()
while IFS= read -r -d '' metal_file; do
    base="$(basename "$metal_file" .metal)"
    air_file="$TMP_DIR/$base.air"
    xcrun -sdk macosx metal \
        -x metal \
        -fno-fast-math \
        -Wno-c++17-extensions \
        -Wno-c++20-extensions \
        -mmacosx-version-min=14.0 \
        -I "$MLX_METAL_DIR" \
        -c "$metal_file" \
        -o "$air_file"
    AIR_FILES+=("$air_file")
done < <(find "$MLX_METAL_DIR" -name "*.metal" -print0)

if [ ${#AIR_FILES[@]} -eq 0 ]; then
    echo "build-metallib: found no .metal files to compile — refusing to write an empty library"
    exit 1
fi

echo "build-metallib: linking ${#AIR_FILES[@]} shaders"
xcrun -sdk macosx metallib "${AIR_FILES[@]}" -o "$METALLIB_OUT"
echo "build-metallib: wrote $METALLIB_OUT"
