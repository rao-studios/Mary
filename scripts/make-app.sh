#!/bin/bash
# WHAT: Assemble Mary.app from a release build with its own TCC identity.
# OUT:  build/Mary.app — binary, mlx.metallib, Info.plist, Abilities, Kokoro and
#       VisionAX resource bundles.
# PIN:  Stable codesign (same as sign-binary.sh). Ad-hoc cdhash breaks TCC.
#       metallib is required; omitting it dies at first GPU use.
#
#   ./scripts/make-app.sh          → build/Mary.app
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/build/Mary.app"
CONFIG=release

cd "$REPO_ROOT"

echo "▸ swift build -c $CONFIG --product Mary"
# --product, not the whole package: every probe and the bench link OpenCV and ONNX
# Runtime through MaryComputerUse now, and this script needs exactly one binary.
swift build -c $CONFIG --product Mary

# Required — not optional. GPU load needs mlx.metallib next to the binary.
echo "▸ mlx.metallib"
./scripts/build-metallib.sh $CONFIG

echo "▸ assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/$CONFIG/Mary" "$APP_DIR/Contents/MacOS/Mary"
# MLX first search rung is the binary's own directory (Contents/MacOS).
cp ".build/$CONFIG/mlx.metallib" "$APP_DIR/Contents/MacOS/mlx.metallib"
cp "Support/Info.plist" "$APP_DIR/Contents/Info.plist"

# Plugin packages are runtime data. Distributable copy under Resources/Abilities.
if [ -d "Abilities" ]; then
    cp -R "Abilities" "$APP_DIR/Contents/Resources/Abilities"
fi

# KokoroAssets falls back to Contents/Resources when Bundle.module is not colocated.
BUNDLE_SRC=".build/$CONFIG/Mary_MaryVoice.bundle"
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP_DIR/Contents/Resources/"
else
    echo "warning: $BUNDLE_SRC not found — Kokoro assets missing from the app"
fi

# VisionAX's region classifier. Same reason as Kokoro: SwiftPM puts the resource
# bundle beside the executable, which is not where a bundled app looks. Without this
# the page-element lane has no model — the media lane still works, since its glyphs
# are drawn rather than learned.
VISION_BUNDLE=".build/$CONFIG/VisionAX_VisionAX.bundle"
if [ -d "$VISION_BUNDLE" ]; then
    cp -R "$VISION_BUNDLE" "$APP_DIR/Contents/Resources/"
else
    echo "warning: $VISION_BUNDLE not found — the page classifier is missing from the app"
fi

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Mary Dev Signing/ {print $2; exit}')"
if [ -n "$IDENTITY" ]; then
    echo "▸ codesign (stable identity: $IDENTITY)"
    codesign --force --deep --sign "$IDENTITY" "$APP_DIR"
else
    echo "▸ codesign (ad-hoc — TCC grants will NOT survive rebuilds)"
    codesign --force --deep -s - "$APP_DIR"
fi

echo "Done: $APP_DIR"
echo "First launch: right-click → Open."
