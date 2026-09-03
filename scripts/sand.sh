#!/bin/bash
# WHAT: Build + STABLE-sign + run Sand — Mary's accessibility/ability bench.
# OUT:  sign-binary.sh, then exec .build/$CONFIG/Sand
# PIN:  Its own script, not a dev.sh flag, because Sand ships its own bundle id
#       (nyc.rao.sand, Support/SandInfo.plist) and therefore its own
#       Accessibility grant. Same stable-signing reason as dev.sh: SwiftPM
#       ad-hoc-signs, the identity IS the cdhash, and every rebuild would look
#       like a new app to TCC — the hands would refuse while System Settings
#       still showed a checkmark. No mlx.metallib: Sand never loads a model.
#
#   ./scripts/sand.sh
#   CONFIG=release ./scripts/sand.sh
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
cd "$REPO_ROOT"

echo "▸ swift build --product Sand ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    swift build -c release --product Sand
else
    swift build --product Sand
fi

BIN="$REPO_ROOT/.build/$CONFIG/Sand"

# Shared with dev.sh and the Xcode launch pre-action — same designated
# requirement, so one grant covers every launch path.
"$REPO_ROOT/scripts/sign-binary.sh" "$BIN"

exec "$BIN" "$@"
