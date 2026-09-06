# Browsing trips

Mary's browsing engine is built from real journeys rather than from a design.
A **trip** is one journey a person takes, written down as legs; a round of the
cycle runs the trips against a live browser, scores each failure by the **layer**
that owns it, fixes that layer in the one generic place it admits, and replays
everything recorded so far. The engine is finished when the scoreboard says so.

Chrome only, on purpose. One browser, driven properly, measures the lane; two
browsers half-driven measure how well the corpus was hedged.

## Why not just write tests

The lane already had tests, and it still shipped a router that opened a
navigation strip, a media lane that reported a proven mute as having done
nothing, and a page question that read the page and said nothing back. Every one
of those was found by driving a browser by hand and was unreproducible the moment
the page changed. What was missing was not assertions — it was **evidence**, kept.

So a trip run writes a recording: the read, the route, the acts and the receipt
together. A page fixture alone can re-argue routing and can say nothing about a
receipt.

## The two rules

**1. A trip names a class of page and a class of row, never a site.**

The point of driving the engine from real journeys is to generalize it. An
expectation written as "the winner is the row labelled X on site Y" generalizes
to nothing: the next page defeats it, and the lane grows a rule per site per
widget forever — the exact thing this design exists to prevent.

So the grammar has **no label field**, by construction. What a leg may assert
about the row it reached is the FACTS the seal decided about it (`RowFacts`), its
affordance, its kind, and its position within its kind. `BrowsingTripValidator`
refuses an address, a host, a page's own words where a class belongs, a fact
nothing derives, and a naming rung that is not one.

The **utterance is exempt**. It is what somebody says out loud, and it may name a
site, because people do.

Addresses live in `~/.mary/trips/stage.json`, outside the repository, keyed by
page class — plus a `phrases` table for the legs that must name something a
staged page holds. The lane speaks site names and never URLs, and a fixture must
not be the one place a query string survives.

**2. The fix goes in the layer that owns the failure.**

`NoScenarioShortcutsTests` enforces the first rule mechanically: no string
literal in the browsing lane is a recorded page's own words or a trip's own
utterance, and every recorded page in the repository appears in the calibration
suites. The second rule is review discipline, and this table is what a round's
author reads before fixing anything.

## The layers

A failed leg gets exactly one layer: the first in pipeline order whose check
fails. Everything downstream of a wrong skill describes a turn nobody asked for.

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
outcome — so a turn-level run that claimed it would report a media leg as passing
when nothing checked it. That is the defect the corpus exists to catch, so the
two runs are kept honest about their halves instead.

A trip answers its own model rounds. A leg claiming the confidence lane is
**never** rescued by an answered round: it declines, and the leg fails at R1
where it belongs.

## Staging the machine

`~/.mary/trips/stage.json`, kept out of the repository because the lane speaks
site names and never URLs. Front doors only: `SpokenAddress.admit` takes a bare
host outright and admits anything deeper only if the person said it, so a seed
with a path is refused by the gate rather than by the runner.

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

The `phrases` are for the legs that must name something a staged page holds. A
corpus that wrote one page's words into a trip would only run against that page,
which is the hard-coding the whole grammar refuses — so those words come from the
machine. A key with no phrase makes its leg unstageable and says which key.

## Running a round

```sh
# Offline: the grammar, the replay net, the guard.
swift test --filter 'BrowsingTrip|TripLayer|NoScenario|NoSiteShortcuts|PageRoute'

# The R1 half, against the real embedding model and the shipped packages.
MARY_EMBEDDING_CALIBRATION=1 swift test --filter BrowsingTripRoutingTests

# Live, engine-level. Signed, or the grants do not hold.
swift build --product mary-web-probe && ./scripts/sign-binary.sh .build/debug/mary-web-probe
.build/debug/mary-web-probe --browser chrome \
    --trip Tests/MaryPluginTests/Fixtures/Trips/read/what-can-i-click.trip.json \
    --record /tmp/round0 --round 0

# Live, turn-level.
./scripts/sand.sh --target com.google.Chrome \
    --trip Tests/MaryPluginTests/Fixtures/Trips/read/what-is-this-about.trip.json \
    --record /tmp/round0 --round 0

# The scoreboard, and this document's own table.
.build/debug/mary-web-probe --score /tmp/round0 --write docs/browsing-trips.md --round 0
```

A trip marked `navigates` opens pages in the browser the person is looking at,
and the probe asks before the first leg. `--yes` skips the prompt; use it only
against a browser window kept for this.

Legs marked `pending` are waiting on a round that has not landed. They are
counted as pending, never as passed or failed — a corpus authored ahead of the
engine has to distinguish "not built yet" from "built and wrong".

## The exit criterion

Two consecutive rounds where: categories other than `context` pass at 90% or
better; every `context` leg's ambient and speech expectations pass; no page-routing
failures remain on the recorded corpus; every open perception finding has a
VisionAX fixture filed; and the guard is green.

## What the browser keeps while Mary works elsewhere

Six invariants, one `context` trip each. "Hardened on its own" is the first
three: the browser's model is written only by the browser's own poll, engine and
navigation detection, and no other surface's turn can reach it.

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

## The round log

### Round T — the instruments and the corpus

39 trips, 57 legs, 8 categories, authored ahead of the engine. The grammar and
its validator, the recording, the recording seams over the engine's existing
boundary, the failure classifier, the scoreboard, both runners, the replay net
and the guard.

### Round 0 — R1, measured

`BrowsingTripRoutingTests` measured every leg that states where its words should
go, against the real embedding model and the shipped packages. Thirteen findings,
recorded as a two-way ledger in that suite: a new one is a regression, and a
fixed one has to be struck off deliberately with the round that did it.

- **An action read as something else**, which costs a model round because the
  confidence lane only runs on an action turn. "Click the download button" reads
  as perceive; "type X into the search box and press return" and "play it again"
  read as converse; "open the third link" reads as converse and reaches nothing.
- **Twins that have not been separated.** `control-playback` and `control-media`
  were separated by naming their surfaces in their summaries. The DESCRIBE twins
  have the same collision and have not been: "what's playing in this tab" reaches
  `now_playing` at 0.82 against `describe_media` at 0.70. So do the LISTING
  twins: "what tabs do I have open" reaches `list_app_windows` at 0.85.
- **A browser question answered by another surface.** "Which tab am I on" reaches
  `list_playlists` at 0.63, and `current_page` is not offered at all.
- **A page skill offered with an editor in front.** "What does this function do"
  with an editor staged reaches `read_page_text` at 0.74 — invariant 5.
- **A shipped verb the corpus does not carry.** "Open a new tab" reaches no
  unique winner, though `new_tab` is shipped and realized by both browsers.

### Round 0 — driven directly against Chrome

The engine was driven live, not only rehearsed. What worked, measured on a real
page: the shell read in 36ms; the page read in 516–590ms for 95–99 rows; a goal
routed to the row named exactly that, with every other row given a disposition
and a sentence; a fill and submit proved by `navigation`; a whole
search-and-open in 5.3s, which is the documented number; and the media lane
refusing `controlsNotFound` on a page with no player rather than pressing
something else. Three findings came out of it.

- **`search_web` opens a result the person never named.** `browsing.mary`
  declares it as "show the results, opening one when the person named which",
  and `WebSearchRecipe.searchAndOpen` arbitrates `pick ?? ""` with `.openResult`,
  which falls back to the page's first answer by design. So a bare "search the
  web for X" walks into a result. Whether it should is a round 3 question,
  because always-opening is masking the missing implied arguments that would let
  "watch a video" open one on purpose.
- **And when it falls back, it says it matched.** The trace reports
  `goalUnmatched` false, so the recipe's own "I couldn't match that, so I opened
  the first result" sentence never fires and the turn claims it found what was
  asked for. That one is not a design question. `search-without-opening` pins it.
- **A package-realized operation is unreachable from the probe.** `new_tab` is
  Command-T through `chrome.managed-ui`, not a binding on the adapter, so the
  engine-level runner cannot dispatch it. It needs the turn, which is a second
  reason that verb is hard to measure.

Two bugs in the instruments surfaced the same way and are fixed. A trip ran
against whatever tab was open while claiming a page class, and now stages or
declares itself unstageable. And `PageRouteVerb.word` prints `openResult` as
"result", so a leg asking about the openResult arbitration was judged against the
inner press a search performs afterwards — a search routes twice, and the leg now
names which route it means.
