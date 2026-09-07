#!/bin/bash
# WHAT: One round of the browsing cycle — build, sign, drive the trips the
#       caller named against Chrome, score them.
# OUT:  <record dir>/*.probe.recording.json and the round's table
# PIN:  TRIPS ARE PASSED IN. The repository does not ship a fixture corpus;
#       a glob of nothing used to run zero legs and still score. Round, then
#       either trip paths, or a record directory followed by trip paths.
#
#   ./scripts/browsing-round.sh 8 ~/.mary/trips/one.trip.json
#   ./scripts/browsing-round.sh 8 /tmp/round8 ~/.mary/trips/*.trip.json
#
set -e

ROUND="${1:?say which round this is}"
shift
if [ $# -eq 0 ]; then
    echo "pass at least one trip (.trip.json) — nothing is globbed from the repository" >&2
    exit 1
fi
if [[ "$1" == *.trip.json ]]; then
    RECORD="/tmp/browsing-round-$ROUND"
else
    RECORD="$1"
    shift
fi
if [ $# -eq 0 ]; then
    echo "pass at least one trip (.trip.json) after the record directory" >&2
    exit 1
fi

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
# AT THE ROUND'S SIZE. A new window takes whatever size the last one had;
# the seeds were staged at 1266×885 and a page twice as wide is read as a
# different page (round 12: the play circle sixty points from where the
# pixels put it).
[ -n "${WINDOW:-}" ] && .build/debug/mary-web-probe --browser chrome --window "$WINDOW" --resize 1266x885 > /dev/null 2>&1 || true

# THE EDITOR THE CONTEXT TRIPS SPEAK FROM, running before anything needs it
# in front; a stage that names an application nobody launched is unstageable.
open -g -a TextEdit 2>/dev/null || true

mkdir -p "$RECORD"
echo "▸ driving the trips"
drive() {
    .build/debug/mary-web-probe --browser chrome --trip "$1" \
        ${WINDOW:+--window "$WINDOW"} \
        --record "$RECORD" --round "$ROUND" --yes > "$2" 2>&1 || true
}
for trip in "$@"; do
    if [ ! -f "$trip" ]; then
        echo "  ✗ not a file: $trip" >&2
        exit 1
    fi
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
        [ -n "${WINDOW:-}" ] && .build/debug/mary-web-probe --browser chrome --window "$WINDOW" --resize 1266x885 > /dev/null 2>&1 || true
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
