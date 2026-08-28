#!/bin/bash
# Build + STABLE-sign + run — the dev launch that keeps TCC grants alive
# across rebuilds. Use this, not `swift run`.
#
# Why: SwiftPM signs the built binary AD-HOC, and an ad-hoc identity is the
# cdhash — it changes on every build, so macOS treats each rebuild as a new
# app and the Accessibility grant silently stops matching. sign-binary.sh
# re-signs with a stable certificate; see its header.
#
#   ./scripts/dev.sh              → debug build, signed, run
#   CONFIG=release ./scripts/dev.sh
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
cd "$REPO_ROOT"

echo "▸ swift build ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi

# THE SHADERS, WHICH `swift build` DOES NOT BUILD. Cheap after the first run
# — the script skips itself when no shader is newer than the library.
echo "▸ mlx.metallib"
"$REPO_ROOT/scripts/build-metallib.sh" "$CONFIG"

BIN="$REPO_ROOT/.build/$CONFIG/Mary"

# Identity detection + codesign live in sign-binary.sh — shared with the
# Xcode scheme's launch pre-action, so terminal and Xcode builds carry the
# SAME designated requirement and match the same TCC grant.
"$REPO_ROOT/scripts/sign-binary.sh" "$BIN"

exec "$BIN" "$@"
