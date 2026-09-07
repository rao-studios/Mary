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
drive() {
    .build/debug/mary-web-probe --browser chrome --trip "$1" \
        ${WINDOW:+--window "$WINDOW"} \
        --record "$RECORD" --round "$ROUND" --yes > "$2" 2>&1 || true
}
for trip in Tests/MaryPluginTests/Fixtures/Trips/*/*.trip.json; do
    name="$(basename "$trip" .trip.json)"
    drive "$trip" "$RECORD/$name.log"
    # THE ROUND'S WINDOW CAN VANISH UNDER IT — closed by a hand, or by a trip
    # that closed the last tab. The engine refuses rather than moving into the
    # person's window (round 10); the round's answer is a fresh window, named
    # again, and the trip once more. Measured in round 11: one lost window
    # turned sixty-three legs unstageable.
    if grep -q "working in is gone" "$RECORD/$name.log"; then
        echo "  ▸ the round's window is gone — opening another"
        open -na "Google Chrome" --args --new-window "about:blank"
        sleep 3
        WINDOW="$(.build/debug/mary-web-probe --browser chrome --front-window 2>/dev/null | tail -1)"
        echo "  working in window ${WINDOW:-?}"
        drive "$trip" "$RECORD/$name.log"
    fi
    sed -n '/the trip —/,$p' "$RECORD/$name.log" | grep -E '^  [✓✗~·] ' || true
done

# THE TURN-LEVEL HALF IS STILL BY HAND. Sand launched from a script never
# shows its window and never starts the trip (measured after round 11: alive
# two minutes, nothing printed, no window on either display); until it can be
# driven headless, the context and journey trips are run through Sand by hand
# with the same --window, and their recordings copied beside the probe's.

echo "▸ scoring"
.build/debug/mary-web-probe --score "$RECORD" --write docs/browsing-trips.md --round "$ROUND"

# THE ROUND'S WINDOW, PUT AWAY. The person's windows are never touched; the
# one the round opened is the round's to close.
if [ -n "${WINDOW:-}" ]; then
    .build/debug/mary-web-probe --browser chrome --close-window "$WINDOW" > /dev/null 2>&1 || true
fi
