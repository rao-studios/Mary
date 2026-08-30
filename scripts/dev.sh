#!/bin/bash
# WHAT: Build + stable-sign + run.
# PIN:  Not `swift run`. SwiftPM ad-hoc-signs; the identity is the cdhash,
#       which changes every build and Accessibility stops matching.
# OUT:  build-metallib.sh, then sign-binary.sh, then exec .build/$CONFIG/Mary
#
#   ./scripts/dev.sh
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

# OUT: mlx.metallib next to the binary. Skips when shaders are current.
echo "▸ mlx.metallib"
"$REPO_ROOT/scripts/build-metallib.sh" "$CONFIG"

BIN="$REPO_ROOT/.build/$CONFIG/Mary"

# Same designated requirement as the Xcode launch pre-action.
"$REPO_ROOT/scripts/sign-binary.sh" "$BIN"

exec "$BIN" "$@"
