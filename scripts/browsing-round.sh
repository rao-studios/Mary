#!/bin/bash
# WHAT: One round of the browsing cycle — build, sign, drive every trip against
#       Chrome, score it, and write the table into docs/browsing-trips.md.
# OUT:  <record dir>/*.probe.recording.json and the round's table
# PIN:  ONE COMMAND, BECAUSE A ROUND THAT TAKES SIX IS RUN ONCE. Rounds 0–7 were
#       driven by hand and every one of them spent its first minutes on a stale
#       binary, an unsealed package or a browser window nobody had opened. The
#       order here is the order those failures taught: seal, build, sign, stage,
#       drive, score.
#       IT OPENS ITS OWN WINDOW. A trip marked `navigates` drives the browser
#       the person is looking at unless something else is in front of it, so
#       this opens a window for the round and leaves theirs alone.
#
#   ./scripts/browsing-round.sh 8
#   ./scripts/browsing-round.sh 8 /tmp/round8        # keep the recordings here
#
set -e

ROUND="${1:?say which round this is}"
RECORD="${2:-/tmp/browsing-round-$ROUND}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

echo "▸ sealing the packages"
swift build --product mary-package-probe > /dev/null
.build/debug/mary-package-probe seal > /dev/null
.build/debug/mary-package-probe check > /dev/null

echo "▸ building and signing the probe"
swift build --product mary-web-probe > /dev/null
./scripts/sign-binary.sh .build/debug/mary-web-probe > /dev/null

echo "▸ a window for the round"
open -na "Google Chrome" --args --new-window "about:blank"
sleep 3
# THE ROUND'S WINDOW, BY ID. Named once here and handed to every trip, so the
# round keeps working in it however many times the person clicks their own
# window meanwhile — the browser's "main" window is whichever they touched last.
WINDOW="$(.build/debug/mary-web-probe --browser chrome --front-window 2>/dev/null | tail -1)"
echo "  working in window ${WINDOW:-?}"

mkdir -p "$RECORD"
echo "▸ driving the corpus"
for trip in Tests/MaryPluginTests/Fixtures/Trips/*/*.trip.json; do
    name="$(basename "$trip" .trip.json)"
    .build/debug/mary-web-probe --browser chrome --trip "$trip" \
        ${WINDOW:+--window "$WINDOW"} \
        --record "$RECORD" --round "$ROUND" --yes > "$RECORD/$name.log" 2>&1 || true
    sed -n '/the trip —/,$p' "$RECORD/$name.log" | grep -E '^  [✓✗~·] ' || true
done

echo "▸ scoring"
.build/debug/mary-web-probe --score "$RECORD" --write docs/browsing-trips.md --round "$ROUND"
