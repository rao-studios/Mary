#!/bin/bash
# WHAT: Launches Mary at a matrix of window sizes and captures each into
#       PNGs for the responsive-layout standard's manual review.
# IN:   scripts/dev.sh's build+sign steps; scripts/window-id.swift;
#       MARY_LAYOUT_CHECK (Core/MaryLayoutCheck.swift).
# OUT:  <out>/<name>-<window>.png, one per size in the matrix below.
# PIN:  Needs Screen Recording permission for the terminal. Does not drive
#       controls — synthetic clicks don't reach SwiftUI popovers; sheets and
#       panes are exercised by hand against these same sizes.
#
#   ./scripts/layout-check.sh [output-dir]
#
set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${CONFIG:-debug}"
OUT="${1:-$REPO_ROOT/.build/layout-check}"
cd "$REPO_ROOT"
mkdir -p "$OUT"

echo "▸ swift build ($CONFIG)"
if [ "$CONFIG" = "release" ]; then
    swift build -c release
else
    swift build
fi
BIN="$REPO_ROOT/.build/$CONFIG/Mary"
"$REPO_ROOT/scripts/sign-binary.sh" "$BIN"

capture() {
    local name="$1" home="$2" studio="$3"
    echo "▸ $name  home=$home studio=$studio"
    MARY_LAYOUT_CHECK="home:${home};studio:${studio}" "$BIN" &
    local pid=$!
    for _ in $(seq 1 40); do
        sleep 0.5
        if swift "$REPO_ROOT/scripts/window-id.swift" 2>/dev/null | grep -q .; then
            break
        fi
    done
    sleep 1
    while IFS=$'\t' read -r id title; do
        [ -z "$id" ] && continue
        local safe
        safe=$(echo "$title" | tr -c 'A-Za-z0-9' '-')
        screencapture -l"$id" -o "$OUT/${name}-${safe}.png" 2>/dev/null || true
    done < <(swift "$REPO_ROOT/scripts/window-id.swift")
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    sleep 0.5
}

# Home matrix — Studio held at a comfortable size while Home's width changes.
capture "home-floor"   "720x520"   "960x600"
capture "home-regular" "1100x700"  "960x600"
capture "home-wide"    "1440x860"  "960x600"
capture "home-wider"   "1900x1000" "960x600"

# Studio matrix — Home held at its floor while the Studio's width changes.
capture "studio-floor"   "720x520" "960x600"
capture "studio-regular" "720x520" "1240x800"
capture "studio-wide"    "720x520" "1440x860"
capture "studio-wider"   "720x520" "1900x1000"

echo "▸ done — screenshots in $OUT"
