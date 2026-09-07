# Browsing trips

A **trip** is one journey a person takes, written down as legs: the utterance,
and the shape of what must happen, in Mary's vocabulary. Production still
drives a trip from a path the caller passes — `mary-web-probe --trip` and
`sand --trip` — and writes a recording: the read, the route, the acts and the
receipt together. Addresses live outside the repository.

The committed fixture corpus is gone. The three journeys that used to be
trips — a watch from a blank page, a window behind another, a minimized
window — are ordinary tests against fakes (`BrowsingJourneyTests`, plus the
stage tests already in `BrowserEngineTests`). A trip file is something you
stage on the machine when you want a live recording, not something this
repository ships.

Chrome only, on purpose. One browser, driven properly, measures the lane.

## Why a trip at all

The lane already had tests, and it still shipped a router that opened a
navigation strip, a media lane that reported a proven mute as having done
nothing, and a page question that read the page and said nothing back. Every
one of those was found by driving a browser by hand and was unreproducible
the moment the page changed. What a live trip run keeps is **evidence**: a
recording a page fixture cannot stand in for, because a fixture re-argues
routing and says nothing about a receipt.

## The two rules

**1. A trip names a class of page and a class of row, never a site.**

The grammar has **no label field**, by construction. What a leg may assert
about the row it reached is the FACTS the seal decided about it (`RowFacts`),
its affordance, its kind, and its position within its kind.
`BrowsingTripValidator` refuses an address, a host, a page's own words where
a class belongs, a fact nothing derives, and a naming rung that is not one.

The **utterance is exempt**. It is what somebody says out loud, and it may
name a site, because people do.

Addresses live in `~/.mary/trips/stage.json`, outside the repository, keyed
by page class — plus a `phrases` table for the legs that must name something
a staged page holds. The lane speaks site names and never URLs, and a
fixture must not be the one place a query string survives.

**2. The fix goes in the layer that owns the failure.**

`NoScenarioShortcutsTests` enforces the first rule mechanically: no string
literal in the browsing lane is a recorded page's own words, and every
recorded page in the repository appears in the calibration suites. The
second rule is review discipline, and this table is what a round's author
reads before fixing anything.

## The layers

A failed leg gets exactly one layer: the first in pipeline order whose check
fails. Everything downstream of a wrong skill describes a turn nobody asked
for.

| Layer | What failed | The fix it admits | What it refuses |
|---|---|---|---|
| **R1** ability routing | The words reached the wrong skill, the wrong intent, or the wrong lane | A route fixture on the right skill **that names its surface**; a spoken value; a sharpened summary; a generic gate in the arbitrator or the triage; package-declared implied arguments | Moving a floor or a margin without a measurement in `EmbeddingCalibrationTests`; a token list naming a site |
| **A** ambient | The wrong application answered, the lead or the front is wrong, a session or scope survived what should have cleared it, a pin was ignored | `BrowserWorld`, the container roster, per-tab scopes, the pin rung, the fetch-first owner table, stage restore in the executor | A browser conditional in `MaryAmbient` or `MaryBrain` |
| **P** perception | The route missed **and no row in the recorded page answers the class** — the reading had nothing to pick | A VisionAX fixture and a detector or classifier change **there**; a new `RowFact` derived at the seal from geometry, grouping or label shape | A label rule; a site rule |
| **R2** page routing | A row answering the class **was** in the reading and the route picked another, or refused | A `RowFact`; a `PageRouteDomain` rule turning a fact into a standing or a structure term; a calibration constant **with the recording that needed it** cited in `PageRouteCalibrationTests` | A comparison on label text; a fourth ladder |
| **E** execution | The route was right; the receipt rank, `landed` or the refusal was not | The one executor's receipt ladder; a settle constant **with its measurement**; the media lane's `mediaState` receipt; stage restore | A per-site settle; a retry loop keyed on a title |
| **S** speech | It landed and nobody heard | The never-silent rungs; the read-back; the ledger route | — |
| **T** timing | Everything passed, past the budget | Measured constants; fewer reads | — |

**P and R2 are the pair that matters.** "Nothing in the reading could have
answered" is a detector finding and belongs in VisionAX with a fixture. "The
answer was in the reading and the route passed it over" is a routing finding.
They are told apart by asking the recorded page whether any row satisfies the
class — which is the whole reason a recording keeps rows and their facts.

## Two runners, two halves

Neither runner can answer for the other's half, and a recording says which
layers it could observe at all.

| | `mary-web-probe --trip` | `sand --trip` |
|---|---|---|
| Drives | the adapter's own `SkillBinding` closures | the whole turn, through `MaryBrain.respond(to:)` |
| Answers | A, P, R2, E, T | R1, A, S, T |
| Cannot see | which skill the words reached, on which lane | `landed`, and which application answered |

`landed` never reaches a `BehavioralActionRecord` — the brain consumes the
outcome — so a turn-level run that claimed it would report a media leg as
passing when nothing checked it. The two runs are kept honest about their
halves instead.

A trip answers its own model rounds. A leg claiming the confidence lane is
**never** rescued by an answered round: it declines, and the leg fails at R1
where it belongs.

Spoken routing for the watch journey is pinned in
`EmbeddingCalibrationTests` (`watch_video`). There is no corpus ledger of
utterances in this repository.

## Staging the machine

`~/.mary/trips/stage.json`, kept out of the repository because the lane
speaks site names and never URLs. Front doors only: `SpokenAddress.admit`
takes a bare host outright and admits anything deeper only if the person
said it, so a seed with a path is refused by the gate rather than by the
runner.

```json
{
  "resultsPage":       "https://…",
  "watchPage":         "https://…",
  "article":           "https://…",
  "consentWall":       "https://…",
  "siteWithSearchBox": "https://…",
  "form":              "https://…",
  "sliderPage":        "https://…",
  "phrases": {
    "address":       "https://…",
    "namedRow":      "click on images",
    "revealTarget":  "scroll down to the comments",
    "sliderTarget":  "set the slider to about a quarter",
    "ambiguousRow":  "click the download button",
    "namedTab":      "switch to the other tab"
  }
}
```

The `phrases` are for the legs that must name something a staged page holds.
A trip that wrote one page's words into the file would only run against that
page, which is the hard-coding the whole grammar refuses — so those words
come from the machine. A key with no phrase makes its leg unstageable and
says which key.

## Running a trip

Pass the trip path. Nothing in the repository is globbed.

```sh
# Offline: the grammar, planted-drift replay, the guard, the fake-engine journeys.
swift test --filter 'BrowsingTrip|TripLayer|NoScenario|BrowsingJourney|PageRouter|WebSearchRecipe|WorkingWindow|WatchRecipe'

# Live, engine-level. Signed, or the grants do not hold.
swift build --product mary-web-probe && ./scripts/sign-binary.sh .build/debug/mary-web-probe
.build/debug/mary-web-probe --browser chrome \
    --trip ~/.mary/trips/what-can-i-click.trip.json \
    --record /tmp/round --round 0

# Live, turn-level.
./scripts/sand.sh --target com.google.Chrome \
    --trip ~/.mary/trips/what-is-this-about.trip.json \
    --record /tmp/round --round 0

# A round of whichever trips you pass.
./scripts/browsing-round.sh 0 ~/.mary/trips/what-can-i-click.trip.json
./scripts/browsing-round.sh 0 /tmp/round ~/.mary/trips/*.trip.json

# The scoreboard.
.build/debug/mary-web-probe --score /tmp/round --write docs/browsing-trips.md --round 0
```

A trip marked `navigates` opens pages in the browser the person is looking
at, and the probe asks before the first leg. `--yes` skips the prompt; use
it only against a browser window kept for this.

Legs marked `pending` are waiting on a round that has not landed. They are
counted as pending, never as passed or failed — a trip authored ahead of the
engine has to distinguish "not built yet" from "built and wrong".

A leg that states only where its words should go is **unmeasured** by the
probe, which routes nothing. The turn-level runner answers for them; the
probe says so.

## What the browser keeps while Mary works elsewhere

Six invariants. "Hardened on its own" is the first three: the browser's
model is written only by the browser's own poll, engine and navigation
detection, and no other surface's turn can reach it.

1. **Nothing another surface does mutates the browser.** A music turn between two
   page legs leaves the tab's result query and landings intact.
2. **Only the browser invalidates the browser.** A hand navigation clears that
   tab's session and retracts its scope; a lead change does not.
3. **The browser is reachable from anywhere, and the person's place is given
   back.** With an editor leading, "mute the video" resolves the browser by recent
   evidence, lands, and leaves the editor in front.
4. **The provider ladder is honoured**: named, then interaction, then pinned,
   then focused, then habit.
5. **The pre-read follows the lead, and a named surface overrides it.** "This
   page" from an editor reads the page; "this function" reads the buffer.
6. **A question never ends silent**, whichever surface leads.
