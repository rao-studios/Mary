#!/bin/bash
# WHAT: Build + STABLE-sign + run Sand — Mary's accessibility/ability bench.
# OUT:  sign-binary.sh, then exec .build/$CONFIG/Sand
# PIN:  Its own script, not a dev.sh flag, because Sand ships its own bundle id
#       (nyc.rao.sand, Support/SandInfo.plist) and therefore its own
#       Accessibility grant. Same stable-signing reason as dev.sh: SwiftPM
#       ad-hoc-signs, the identity IS the cdhash, and every rebuild would look
#       like a new app to TCC — the hands would refuse while System Settings
#       still showed a checkmark.
#       MLX's shaders go beside the binary, so a page read runs the classifier's
#       backbone on Metal; the timeline's perceive line names the backbone that
#       ran ("classify 9.8 ms on mlx-metal"). FRIGATE_VISION_BACKBONE=onnx runs the
#       CPU backbone instead, which is the whole A/B.
#
#   ./scripts/sand.sh
#   CONFIG=release ./scripts/sand.sh
#
# Pointed at something, without a click:
#   ./scripts/sand.sh --target com.google.Chrome
#   ./scripts/sand.sh --target com.google.Chrome --read-page
#   FRIGATE_VISION_BACKBONE=onnx ./scripts/sand.sh --target com.google.Chrome --read-page
#   ./scripts/sand.sh --target com.apple.Safari --read-page \
#       --say "open the first result" --auto
#   ./scripts/sand.sh --target com.google.Chrome \
#       --say "search for alpine touring boots" --auto --arg query="alpine touring boots"
#
# Screenshotting the bench (Sand owns its own windows, not Mary's):
#   swift scripts/window-id.swift "" Sand
#   screencapture -o -l<window id> /tmp/sand.png
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

# Close to free when the shaders are current. Without them a page read keeps the ONNX
# backbone on CPU and says so — Sand still runs.
# Frigate is a URL dependency now: prefer a sibling checkout when one exists,
# otherwise the copy SwiftPM resolved under .build/checkouts.
FRIGATE_METALLIB="$REPO_ROOT/../Frigate/scripts/build-metallib.sh"
[ -x "$FRIGATE_METALLIB" ] \
    || FRIGATE_METALLIB="$REPO_ROOT/.build/checkouts/Frigate/scripts/build-metallib.sh"
"$FRIGATE_METALLIB" "$CONFIG" --package "$REPO_ROOT" \
    || echo "sand: no mlx.metallib — page reads will use the ONNX backbone on CPU"

BIN="$REPO_ROOT/.build/$CONFIG/Sand"

# Shared with dev.sh and the Xcode launch pre-action — same designated
# requirement, so one grant covers every launch path.
"$REPO_ROOT/scripts/sign-binary.sh" "$BIN"

exec "$BIN" "$@"
