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

### Round 0 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 0 | 4 | 0 | 0 | 0% | P 1 · R2 1 · E 2 |
| arrive | 2 | 4 | 0 | 0 | 33% | E 4 |
| context | 1 | 5 | 1 | 6 | 17% | P 1 · R2 2 · E 2 |
| media | 0 | 1 | 0 | 6 | 0% | P 1 |
| read | 4 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 2 | 0% | — |
| search | 1 | 7 | 0 | 0 | 13% | R2 4 · E 3 |
| tabs | 1 | 0 | 4 | 0 | 100% | — |
| **all** | **9** | **21** | **10** | **14** | **30%** | P 3 · R2 7 · E 11 |

Exit criterion not met: no leg ran in recovery; act at 0% — under 90%; arrive at 33% — under 90%; media at 0% — under 90%; search at 13% — under 90%; context has 5 failing leg(s); 7 page-routing failure(s) on the recorded corpus.

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
declares itself unstageable.

### Round 0 — the corpus driven, with staging

Every trip the probe can stage was driven against Chrome on real pages. Four
findings in the engine, each landed in its layer by the classifier:

- **The address readback could not see Chrome elide a scheme (E, fixed here).**
  Three trips in a row could not stage — "couldn't find the address bar" — on a
  browser that reported the field found and focused. Ten keyboard acts, three
  type-and-retry rounds, every readback refused: the omnibox shows a recognised
  address without its scheme, and a literal prefix test called a correct type a
  failed one. Found by the corpus, not by reading the code. The readback now
  tolerates exactly Chrome's elisions and nothing looser, and a refused readback
  logs its shape and never the address.
- **`settle` conflates "arrived" with "changed" (E).** It waits for the title or
  address to differ from before. A reload, a back to a same-titled page, and a
  navigation to the page already open all arrive without changing either — and
  all three burn the full 10s budget and report "didn't finish loading".
  `arrive-by-name` and `transport-round-trip` hit it.
- **A reveal claims `landed` with no receipt at all (E).** `scroll-to` reported
  `landed: true` and an empty receipt list. `landed` is meant to rest on the top
  three receipts only; a scroll has a sign at best.
- **A site search does not remember it made a results page (R2).** After
  `fill_in_page` with submit on a site's own box, "open the first one" routes as a
  bare press over the whole page — only `search_web` sets the remembered query.
- **Furniture wins a result pick on an ordinal (R2).** "Open the second one"
  selected an `inForm` navigation-strip row with no press affordance. The fact is
  on the row; the domain rule does not yet make it ineligible for `.openResult`.
- **A control read twice looks ambiguous (P).** "Images" got a clarification
  because VisionAX emitted the tab twice, both `duplicateLabel`. The router was
  right to ask; the reading made one control into two.
- **No row named `link` as its kind on a results page (P).** 93 rows read; "the
  third link" had nothing to count. The kind naming belongs to the detector.

What passed, on real pages: every read trip; the omnibox search path including
the long-query retype loop and forward-delete against completion; the echo and
strip refusals on a real results page.

### Round 0 — the census: what a person says that the corpus had not

The corpus was authored from the engine's own verbs. `BrowsingGapCensusTests`
walked in from the other side — forty-five things a person actually says at a
browser — and rehearsed each through the real gates on a real stage. Doing so
first exposed that the stage had been empty: a hand-built snapshot holds no
application profiles, so every rehearsal until then had run with no `web-page`
class standing. `BrowsingRehearsalSnapshot` now loads the graph the way Mary
does; re-measured, twelve of thirteen ledger findings reproduced identically and
one was struck as the instrument's. The census then found four classes, and
fifteen of its sentences are trips in the ledger now.

- **The confident wrong action — the class that matters most.** A skill wins the
  corpus, the lane dispatches with no model round, and it is the wrong act
  entirely. `reload_page` is a magnet: "save this page" (0.81), "copy the link"
  (0.76) and "find the word…" (0.70) all reach it on the confidence lane.
  "Fill in my email address" reaches `open_location` and would type that
  sentence into the address bar. **Proven live through the whole turn in Sand:**
  "save this page" read as operate, won `reload_page` uniquely, dispatched, and
  reloaded the page — then reported "didn't finish loading", which is the
  `settle` defect meeting it. The grammar gained `mustNotReach` and `lane: none`
  to say exactly this. The fix is a summary that says what each verb *is*, never
  a token list naming these sentences.
- **Cross-surface leaks with a browser in front.** "Close this tab" → a coding
  editor's split; "stop loading" → the typer's stop; "read the comments" → a
  project corpus document; "turn the volume up" → the music app, the transport
  twins on the variant their summaries did not separate.
- **Synonyms for shipped verbs.** "Refresh" reaches nothing though `reload_page`
  ships; "how many tabs" nothing though `list_tabs` does; "check the box…",
  "press the blue button" and "submit the form" nothing though `click_on_page`
  does; "read me the first paragraph" reaches the wrong twin of the two page
  reads. Package data — a fixture that names its surface — is the fix.
- **Verbs that do not exist.** Reopen a closed tab, duplicate, close the others,
  select all, reader view, a dropdown's option, captions, the next video, a
  relative seek, downloads, history, and "send this page" elsewhere. Round 3's
  list grows by these. What could not be staged honestly: the
context trips (another application must lead), the media trips (the seed is a
file page, not a watch page — zero controls reveal), and the consent wall. And `PageRouteVerb.word` prints `openResult` as
"result", so a leg asking about the openResult arbitration was judged against the
inner press a search performs afterwards — a search routes twice, and the leg now
names which route it means.
