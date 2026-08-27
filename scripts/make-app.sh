#!/bin/bash
# Assemble Mary.app from the release build — the "real use" packaging that
# owns its own TCC identity (mic / speech / accessibility) instead of the
# terminal's. Signed with a STABLE identity when one exists (Apple
# Development / "Mary Dev Signing") so TCC grants survive rebuilds — see
# scripts/dev.sh for why ad-hoc breaks them. Distribution signing is out of
# scope.
#
#   ./scripts/make-app.sh          → build/Mary.app
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$REPO_ROOT/build/Mary.app"
CONFIG=release

cd "$REPO_ROOT"

echo "▸ swift build -c $CONFIG"
swift build -c $CONFIG

if [ -f "./build-metallib.sh" ]; then
    echo "▸ mlx.metallib"
    ./build-metallib.sh $CONFIG
fi

echo "▸ assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp ".build/$CONFIG/Mary" "$APP_DIR/Contents/MacOS/Mary"
[ -f ".build/$CONFIG/mlx.metallib" ] && cp ".build/$CONFIG/mlx.metallib" "$APP_DIR/Contents/MacOS/mlx.metallib"
cp "Support/Info.plist" "$APP_DIR/Contents/Info.plist"

# Plugin packages are runtime data, not compiled Swift constants. The loader
# also sees the source-tree folder in development; a distributable app carries
# the same declarations under Resources/Abilities.
if [ -d "Abilities" ]; then
    cp -R "Abilities" "$APP_DIR/Contents/Resources/Abilities"
fi

# The MaryVoice resource bundle (Kokoro models) — KokoroAssets falls back to
# Contents/Resources when Bundle.module isn't colocated with the binary.
BUNDLE_SRC=".build/$CONFIG/Mary_MaryVoice.bundle"
if [ -d "$BUNDLE_SRC" ]; then
    cp -R "$BUNDLE_SRC" "$APP_DIR/Contents/Resources/"
else
    echo "warning: $BUNDLE_SRC not found — Kokoro assets missing from the app"
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
