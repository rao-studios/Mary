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
  list grows by these.

### Round 1 — the twenty-two, resolved by cause

Round 0's failures collapsed to ten causes; nine were fixed in the layer that
owned them, and the tenth (verbs that do not exist) waits on round 4. Live on
Chrome the corpus went from **30% to 63%**, and the layer column tells the story:
**E fell from nine to one**, R2 from seven to four, while P rose from three to
eleven — not a regression, but failures moving down the pipeline to where they
actually live, as the engine stopped masking them.

| Category | Round 0 | Round 1 |
|---|---:|---:|
| arrive | 33% | **100%** |
| read | 100% | 100% |
| search | 13% | **63%** |
| act | 0% | **63%** |
| tabs | — | **100%** |
| all | 30% | **63%** |

What was fixed, each in its own layer:

- **A navigation had no receipt at all**, so every open, back, reload and search
  reported proven work as unproven. `PageInteractionCommandKind.navigate` is the
  receipt rank one had been missing, engine-only so no model-authored plan can
  steer the browser through a page grammar. The search recipe's three hand-set
  `landed: true` lines are gone.
- **"Arrived" and "changed" were the same claim.** A reload lands on the same
  title by definition; demanding a change burned the full budget and then called
  it a failure. Reload now settles on quiet, back and forward on the history
  flipping, and opening the page you are already on is an arrival.
- **A shell button was pressed with a click Chrome ignores.** Measured
  unambiguously: Back was found and clicked and nothing moved, five polls later,
  and Mary said "Went back" about a page she had never left. It goes through the
  control's own `AXPress` now, with the HID click as the fallback.
- **A position counted the page's furniture.** Three legs picked the same
  navigation strip. Positions recount over content; names still reach anywhere.
- **A bare search walked into a result** the package never said it would open.
- **A site's own search box made a results page nobody remembered**, and the read
  that was about to use that memory was the thing clearing it — order was the fix.
- **One control read as two nested rows** made naming it a question.
- **A reveal hovered the page's midpoint**, so a player anywhere else read as no
  player at all.
- **Nine route fixtures** moved seven sentences: "fill in my email address" from
  the address bar to the page's own field, "check the box…" and "press the blue
  button" and "submit the form" to `click_on_page`, "read me the first paragraph"
  to the right one of the two page reads, plus "how many tabs" and "play it from
  the start" from reaching nothing. No floor and no margin moved.

What round 2 owes, now that nothing masks it:

- **The media transport cannot be measured at all (P × 8).** On the staged watch
  page the reading returns zero controls, so every transport verb refuses
  `controlsNotFound`. The player region fix aims the reveal correctly; the
  detector still finds nothing there. This needs a VisionAX fixture from that
  page before anything else in `media` can be believed.
- **A real search field is not named as a field (P × 2).** Wikipedia's own search
  box reads as a button, so `fill_in_page` reaches it through the candidate
  fallback rather than as the field it is.
- **No row is named `link` on a results page (P × 1)**, so "the third link" counts
  rows of no named kind.
- **`reload_page` is still the magnet** for "save this page" and "copy the link",
  because no save or copy verb exists to lose to. Round 4.

### Round 2 — the perception layer, and the media lane's missing receipt

Driven by the scoreboard rather than the design list: round 1 left eleven
perception failures, eight of them the media transport being unmeasurable at all.
Live on Chrome the corpus went **63% to 77%**, media from **0% to 50%**, and P
from eleven failures to three.

| Category | Round 0 | Round 1 | Round 2 |
|---|---:|---:|---:|
| arrive | 33% | 100% | 100% |
| read | 100% | 100% | 100% |
| search | 13% | 63% | **75%** |
| act | 0% | 63% | **75%** |
| media | 0% | 0% | **50%** |
| all | 30% | 63% | **77%** |

**The media diagnosis, from the pixels rather than the code.** Capturing the
exact crop the lane reads showed a paused player with a poster frame, one big
play circle over the picture, and no control bar anywhere; hovering it added only
a small volume icon. VisionAX's own trace confirmed the shape of it — the
detection is entirely bar-first, hunting a progress track with blobs under it,
and every candidate was rejected for thickness or for having no blobs. Three
things followed:

- **The reveal never aimed at the player, and the round-1 fix for that was
  inert.** `playerRegion` reads the reading's rows and a `.media` reading has
  none, so it always answered nil and the retries went on hovering fractions of
  the whole page — one of them above the video entirely. One `.elements` read on
  the first retry answers where the picture is, and only on the path where the
  blind look already failed.
- **`controlsVisible` means "a bar was found", which is a different question from
  "is there anything to drive".** A big play circle is the control a person
  presses without thinking, and the lane refused `controlsNotFound` about it.
  It is now a transport for the verbs it can serve — play, pause, toggle — while
  volume, seek and full screen still need the bar and still refuse by name. The
  glyph's NAME is not trusted: VisionAX matched this one as `exitFullscreen` at
  0.38. It is a place to press, and the press is proved by looking again.
- **The media lane verified in prose and issued no receipt** — the last of the
  three places `landed` was claimed without one. It re-perceives and refuses
  `stateUnchanged` when nothing moved, which is real proof, and then returned it
  as a sentence, so a mute that had demonstrably worked reported `landed: false`
  and the turn tried something else. That is the reported "mute the video runs a
  web search" in its final form. `mediaState` is the receipt, and "already in
  that state" carries one too, because already-true is still proven.

Driving it live: paused → play through the centre circle, verified. Pause, play,
unmute and seek all land on `mediaState`.

**What round 3 owes.** Two transport verbs still refuse `stateUnchanged` after
acting: `mute` (the volume glyph matches a real speaker about half the time, so
the change cannot be seen) and `go full screen` (the page frame changes under the
second look). A seek with no track needs the player playing first. And on the
routing side: "the third link" and "the second one" now reach real content but
land one row off, and a site's own search box still reads as a button rather than
a field — a VisionAX naming gap, not a routing one.

### Round 3 — proving an act, and a lesson about what a live page can measure

Media reached **75%**: five of the six transport verbs now land. Two changes, and
one finding about the method itself that matters more than either.

- **"I cannot see whether it worked" is not "it did not work."** The media lane
  had one failure sentence for both, so a mute on a player whose volume glyph the
  reading could not make out was reported as `stateUnchanged` — "I pressed it,
  but it's still unmuted" — about a video that may well have gone silent. Sound
  is not visible. A verdict is now `proved`, `unchanged` or `unreadable`, and the
  unreadable case is delivered-but-unverified: rank five of the ladder, which
  existed for exactly this and was never reachable.
- **Full screen is proved by the page, which the shell already carries.** The old
  test compared the player's bar before and after, and no bar was legible either
  side, so it could never fire. Going full screen takes the frame from the window
  below the toolbar to the whole window — measured, 1266×765 to 1920×1080 — and
  that is free evidence the engine already had in hand.
- **`mute` remains an honest failure, and stays recorded.** The glyph reads "not
  muted" both before and after, so the verdict is right to refuse. The volume
  control is found by POSITION, because a real speaker icon matches the drawn
  silhouettes about half the time; if the position is wrong the press lands
  elsewhere. That belongs to the detector.

**A LIVE RESULTS PAGE CANNOT MEASURE AN ORDINAL.** Running the same corpus twice
gave the same staged seeds 61, 72, 74 and 75 rows, and the `act` and `search`
numbers moved with them — down as readily as up, with no code between the runs.
A leg asserting "the second result" against a page whose content changes every
run is measuring the page, not the router. The division the instruments were
built for is the answer, and round 4 should enforce it: **live runs prove the ACT
path — it reached a row, it landed, it said something — and RECORDED pages prove
the ROUTING**, through the replay net, where the read is fixed and a change in
the answer means a change in the router. Until those ordinal assertions move,
the `act` and `search` percentages should be read as noisy.

One instrument bug fixed on the way: a mismatch could print "reached by
contained, not contained" — the basis branch reporting a comparison it had not
failed, because the row was refused for a reason no branch covered. It now names
the real reason, or says the class admits nothing on that page. What could not be staged honestly: the
context trips (another application must lead), the media trips (the seed is a
file page, not a watch page — zero controls reveal), and the consent wall. And `PageRouteVerb.word` prints `openResult` as
"result", so a leg asking about the openResult arbitration was judged against the
inner press a search performs afterwards — a search routes twice, and the leg now
names which route it means.

### Round 4 — the page's own accessibility tree, and a vocabulary for pointing at it

Round 3 ended saying the live percentages were noisy because a leg asserting "the
second result" against a page whose content changes every run measures the page.
Round 4 did not start there. Three reported failures did — a person asked what was
on the page in Chrome and was told "Chrome."; asked again and was told "you're
looking at whatever webpage is open"; asked to click the first link and was told
"Links." — and following them down found the same answer under all three.

**Nothing was offered.** Not the wrong skill: none. `"Can you click on the first
link"` scored `click_on_page` at 0.563 against a floor of 0.62, and
`"What's on this page right now on Google Chrome"` scored `read_page` at 0.597.
Bare, the same sentences score 0.623 and 0.805. **The ranking was already right
in every case and the floor threw it away.** A politeness frame costs 0.06 to
0.21 of sentence similarity; a named surface costs about as much again. Neither
is a calibration problem — 0.62 is the right floor for a sentence that is all
task, and lowering it to admit these would admit everything at 0.56 too.

`RoutingQuery.bareRequest` is the fix, and it is `firstLine`'s argument one level
in: **a request carries two things that are not about the task** — the politeness
that asks for it and the surface it names — and both are already routing FACTS by
the time the sentence is vectorized, the surface as `namedApplications` and the
request as the intent. Leaving them in spends the sentence twice. The bare form is
scored as a SECOND reading and taken at its best, so a request that needs its own
words keeps them. The surface names come from the installed packages, never from a
list in the file. A correction frame is a frame too: dictation runs "no I'm not"
and the question after it into one sentence with no punctuation, and the rejection
was being scored as though it were the request.

Five of the six reported sentences now reach a unique skill on the confidence lane
with no model round. Two known findings stopped reproducing and were struck.

**The other half was perception, and the answer had been written down and
deferred.** `PageReaderLane` carried a TODO naming exactly what was missing: the
accessibility lane, its Chromium wake, and the merge. The reason it mattered is
what the reported failures were really about — asked to click the first link, the
pixel lane offered rows called `link 1`, `star`, and `Diew Special`.

Chrome builds no web-content accessibility tree until an assistive client
announces itself, and until then the walk returns nothing — indistinguishable from
a page with nothing on it. Woken (measured here at **2286 ms**, matching the
reference port's 2.3 s), the same page answers in full. Both lanes on one page,
back to back: the pixel lane read 108 rows and could offer **four**, naming the
page's own menu "Diew Special" and a heading "1ooked first"; the walk found sixty
with the words their author wrote. The merge is IoU ≥ 0.6, the walked row taking
the rectangle and the seen row keeping the page's shape, because grouping is
geometry the tree does not publish. On the same page, offered rows went **4 → 32**.

**And then a person still could not point at anything.** Every way of naming a row
was a WORD — its label, its kind, its position in reading order — and nobody reads
a page in reading order. They say "the search box at the top", "the third link in
the sidebar", "the button at the bottom of the page". `PageRegion` is that
vocabulary: six places found from geometry over the rendered page, never from
markup or a landmark role, so they mean the same thing on a site that marks its
structure up and on one that draws it. The same closed-English-vocabulary shape as
`SpokenOrdinal.words`, and on the same side of the doctrine for the same reason
"third" is.

Three things had to be true together, and each was measured live:

- **The place has to be found, not assumed.** A first rule took every slice of the
  page that beat half the busiest one; on a search page a dense strip of chips set
  a peak its neighbours could not reach, the column was carved down to it, and the
  page's own results were reported as a sidebar. Asking instead for the narrowest
  span that carries most of the page lets the column grow to fit the content.
- **A place is a gate, not evidence.** "The first link in the sidebar" on a page
  with no sidebar scored nothing on the naming ladder, fell through to meaning, and
  confidently opened a link in the body. A person who says where has narrowed the
  page; a row elsewhere is not a worse answer, it is not an answer.
- **A place is spent once.** "The search box at the top" scored 431 against the row
  that IS the search box, where "the search box" scored 624 — three words that had
  already done their work, scored again as meaning. Same fix as `bareRequest`, one
  layer down.

The brief speaks the same vocabulary it accepts: *"Laid out with 9 things across
the top, 4 things down the left, 26 things in the page itself, 17 things down the
right, and 5 things along the bottom."* Every place named there is a place the
resolver takes back. **That loop is the point** — a brief describing the page in
words the resolver did not accept would invite requests it then had to refuse.

**The sweep is the instrument, and it is what makes this general.** `--landscape`
drives every page the machine is seeded with and asks the same five generic
questions of each. Seven page shapes — an encyclopedia article, two search engines,
a feed, a form, a media page, a site with its own search — and the same questions.
Six of seven answer "the search box at the top"; the seventh has no search box.
That is the difference between a trip that works and a rule that holds.

#### Three defects the driving found that no test would have

- **The wake broke the shell.** A browser window is about seventy accessibility
  nodes until its page tree is built and several thousand after, and the shell's
  own address-field lookup walked all of them: 700 ms, twice a read, three times a
  navigation, and the detail read at the end began returning nil — so Mary said
  "I couldn't find the address bar" about a field she had just typed into.
  `Options.shell` stops at the web area's door: **2247 nodes → 68, nil → the real
  address in 46 ms.** A shell read has no business inside the page.
- **A latched Command key.** After a round of browsing, typing stopped reaching
  Chrome while chords still worked. `KeyChordPress` posts its key-up carrying the
  chord's modifiers — which tells the session Command is still held, with nothing
  anywhere to lower it — and `CGEvent` inherits the session's modifiers, so every
  character `KeyboardTyper` sent became a menu shortcut. Forty-one typed
  characters vanished, three attempts running. The chord now puts the modifier
  down, and the typer states its own empty flags, which is the honest rule with
  nothing stuck too: a person resting a hand on Command while Mary types must not
  have their text eaten.
- **Two links in one rectangle.** A search page publishes "Accessibility help" and
  "Skip to main content" at the identical frame; both are real and at most one is
  drawn, and they became the first two rows any ordinal counted. A page cannot draw
  two different links in the same place.

#### The replay net, for the first time with something to replay

No recording had ever been committed, so `BrowsingTripReplayTests` had been
passing on an empty corpus. Forty-three recordings later it reported six drifts,
and **every one was the net's own fault**, which is the best possible outcome for
a first run:

- Four were the replay arguing against the wrong read. A leg reads the page twice
  — once to route, once after the act to prove it — and the net took the LAST, so
  a route was re-argued against the page that came after the press. On a leg that
  navigated, that is a different page entirely; one compared a results page with
  the article it had opened.
- Two were the meaning term. It comes from the turn's own element index, which no
  offline run can rebuild — so a replay that recomputed it was arguing a different
  read. The recording already carried the score it used, per row; it goes back in
  now. **A route is a pure function of a read, and the meaning scores are part of
  the read.**

Drift is zero. What remains is a two-way ledger of five open failures, each also
in the live scoreboard, now kept as arithmetic: the day one changes, it changed
because the router did.

#### The numbers

**44% → 77%, and 43 legs ran where 16 had.** That second number is the real one:
the unstageable count fell from 50 to 18 once navigation worked again. `arrive`,
`read` and `tabs` are at 100%. Round 3's 74% was measured over 16 legs and is not
comparable.

What is left is honest and named: `act` and `media` at 63%, `search` at 75%, four
perception failures that belong in the detector's recall, and three page-routing
misses. `recovery` still runs nothing — every leg of it needs a person.

#### What round 5 should take

- **The detector's recall on a results page**, which is four of the ten remaining
  failures and the one layer this round did not touch. Both are result pages whose
  answer rows the reading did not group.
- **Below the fold.** The walk drops off-viewport rows, so "click the link to X"
  fails when X is one scroll away — and the landscape is honest only about what is
  on screen. Navigation, scrolling and a single landscape are the same problem.
- **A skip link is not the first link.** Two pages put one there.

### Round 5 — the fold, and two things that were not what they were filed as

Round 4 named three things for round 5: the detector's recall on a results page,
below the fold, and skip links. All three were taken. Two of them turned out to be
something other than what round 4 had called them, which is most of what this round
is worth.

**Below the fold is not a bigger read. It is a walk.** The obvious first question
was whether Chrome's accessibility tree holds the whole document and the walk was
merely clipping it away. Measured on a whole encyclopedia article, at eighty deep
and sixty thousand nodes: **811 nodes exist for the entire page, none of them off
screen**, and everything below the fold is published as a **one-pixel sliver at the
viewport's edge carrying no name at all**. There is nothing further to read. So
"read more" was never the answer to "click the link to X six screens down"; moving
the page is, and `scrollToOnPage` was already the walk — no act had ever used it.

An act that cannot reach a named row now looks for it and tries again, and puts the
page back if it was not there. Two rules keep it honest:

- **Only a name searches.** "The third link" means the third of the ones the person
  can see; scrolling to count things they never saw answers a question nobody asked.
- **Only a weak match searches.** A refusal, or a match reached on MEANING ALONE.
  Measured live: "Ski mountaineering" reached "Ski touring" on 0 naming and 809
  meaning. Containment is NOT weak, and the distinction cost a test to find —
  "Randonnee racing equipment" reaching "Equipment" looks like the same guess and
  is not, because the row's own name sits inside what the person said. Searching on
  containment too would spend four page reads on most acts to improve a few.

**A detour worth recording because it failed.** The obvious fix for the meaning-only
match was to make the router refuse it: a name must be answered by a name. Tried,
measured, reverted. Meaning alone is genuinely how a named thing is reached when the
page spells it differently, and forbidding it broke a pinned case
(`meaningCarriesACandidateTheWordsOnlyScatter`) and drifted a recording. The router
is right to answer; the ACT is what should not settle for the answer without
looking. That is now written into `clearsFloor` so nobody tries it a second time.

**"The recall belongs in the detector" was wrong about four legs out of ten.** The
trip classifier judged a leg's row class against `pageReads.last` — the page read
AFTER the act, to prove it — rather than the one the route was argued on. A leg that
navigates was therefore judged against its own destination: "open the second one"
was checked against the article it had just opened, which of course holds no second
result, and the verdict read "no row in this reading answers the class — the recall
belongs in the detector". **The identical fault had been found and fixed in
`BrowsingTripReplayTests` in round 4 and not looked for here.**

Fixed, the four separate honestly:

- `music-between-two-page-legs[2]` **passes outright**.
- `site-search[1]` moves from P to **R2**, with a sentence somebody can act on:
  "reached row 37, which is number 3 of its kind, not 1".
- `search-then-open-second[1]` stays **P**, and now genuinely is: on the read the
  route was argued against, no row sits in a result group at all.

**Result grouping from shape.** The accessibility lane made naming better and
grouping worse — a walked row that lands on no seen row is added with no group, and
`inResultGroup` is read off the group. `PageListDerivation` fills that in from
geometry: three or more rows at the same left edge, comparable width, regular gaps,
in the page's own column. Only ever adds; a row the reading already grouped keeps
its group. Live on a results page it took the openResult pool from unanswerable to
**55 of 100 eligible**.

**Skip links: two refutations and no detector.** The idea was that a skip link is
positioned off the page and clipped back in, which would make it geometry the walk
can see. It is not — on a search page "Skip to main content" is drawn at 110×44
**eleven points inside** the page's own left edge and is hidden by means
accessibility does not report at all. The machinery built on that reading was
removed rather than left in on a false premise. The second idea was that the pixel
lane could witness it, being the only lane that sees what is DRAWN. Measured across
three sites, counting walked rows no seen row overlaps: **4 of 48, 2 of 56, 0 of 60
— and the skip link is in none of them, while "Clear", "Main menu" and "About this
result" are.** Using that as evidence would hide three visible things to hide one
invisible one. `RowFacts.notDrawn` and the gate that reads it are kept, because the
rule is right; nothing sets it, because neither lane publishes the evidence.

**Two instrument repairs.** A recording did not carry a row's `region` at all, so
every rule that reads one — the gate refusing "the third link in the sidebar" on a
page with no sidebar, the list derivation that only groups the page's own column —
was inert offline and could not be regression-tested. And the replay ledger was
keyed on a sentence containing a live row count, so it would have reported four
regressions and four fixes every round and meant nothing. It keys on trip, leg and
layer now.

#### The numbers, and why they are not the headline

Three whole-corpus samples this round: **77, 72, 74**. Round 4 reported 77 from one
sample. The spread is run-to-run variance — round 3 said this and it is still true —
and **round 5 cannot claim to have moved the live percentage.** Two of the failures
in the low sample passed on immediate re-run, and one was `addressFieldNotFound`
during a back-to-back corpus run, which is the instrument driving Chrome harder than
any person would.

What is claimable is the layer column, which does not average away: one P failure
became a pass, one became a statable R2, and the remaining P is genuinely
perception. Read the layers, not the rate.

#### What round 6 should take

- **Why `PageListDerivation` did not fire on the one remaining P.** The read has 79
  rows, fourteen bands, no result group, and twenty-two ungrouped pressable rows in
  the main column — which is exactly the shape it is meant to answer.
- **`arrive` is fragile under a corpus run and not alone.** Either the runner
  settles the stage between trips or it stops claiming the failure is the engine's.
- **A row that is published and not drawn.** Neither lane can see it today. That is
  a VisionAX question, filed with its measurement.

### Round 6 — a settle that watches instead of waiting, and a chord that knows where it is aimed

Round 5 left two questions and called the third a VisionAX matter. Both questions
had the same shape of answer: the thing being blamed was not the thing that was
wrong.

**"The recall belongs in the detector" was wrong a second time.** Round 5 had
already moved three of four such failures out of the P column by fixing which page
the classifier read. The last one — `search-then-open-second[1]` — stayed P and was
written up as "genuinely perception". It was not. `PageListDerivation` fires
correctly on that page: measured live, **55 of 107 rows eligible as results**. What
differed was the READ it was given. The same search across one round recorded
readings of 79, 104, 107 and 108 rows, and on the 79 the results had not been
grouped yet, because `settleForResults` was a **flat 900 ms sleep** followed by one
read of whatever happened to be drawn.

A settle needs a signal, not a sleep. Reading the whole page twice to find out
whether it had stopped changing would double the cost of every search, so the
settle polls the browser's **own accessibility tree** — a bounded walk of a few
hundred nodes, cheap since round 4 woke it — until the count holds still twice
running, and only then takes the expensive read. The old sleep is both the floor
and the budget: a page that never settles is read at exactly the moment it would
have been before. **The leg passes four runs out of four.**

**A chord had no idea where it was aimed.** `KeyboardTyper` has always checked the
frontmost bundle before every chunk it types. `KeyChordPress` checked nothing — and
the same code uses them one after the other: focus the address bar with ⌘L, then
type. During a back-to-back corpus run the browser lost the stage between trips,
⌘L went to whatever had it, and the navigation reported "I couldn't find the
address bar" about a browser it had never reached. Round 5 filed that as the
instrument driving Chrome too hard. It is a real hazard: **a chord is the stronger
of the two gestures**, and ⌘W in the wrong window closes somebody's document.

Chords take an optional `targetPrefix` now, and every chord in the navigation path
passes it. Nil still means anywhere, which is not an oversight — a system chord or
a media key has no application in mind and must not be made to invent one.

#### The numbers

Two whole-corpus samples: **79% and 81%**, against round 5's 77 / 72 / 74. The low
end of this round sits above the high end of the last, which is the first time this
work has moved the rate outside its own noise band. More usefully, the layer column
moved and held across both samples: **P fell from 4 to 2**, `arrive` is 100% in
both, and `search` reached 88%.

The two remaining P failures are both the media lane on a file page — "0 controls
seen, controls visible: false" — which is a detector question and has been one since
round 2.

#### What round 7 should take

- **`act` at 63%, unchanged for three rounds.** Two R2 failures — "check the box
  that says remember me" and a named row on a feed — both of the same shape: a goal
  naming something the reading spells differently. That is the oldest open finding
  in the ledger and nothing has been aimed at it.
- **`recovery` has never run a leg.** Every one of its seven needs a person: a page
  that stalls, focus taken mid-plan, a second browser. Three are already engine
  tests with fakes. The rest should either become fakes or stop being counted as
  unstageable, because a category that can never run flatters nothing and warns
  nobody.
- **The exit criterion is still measured on one run.** After round 5's 77/72/74 it
  should require two consecutive rounds, which is what it says and not what it does.

### Round 1 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 5 | 3 | 1 | 5 | 63% | R2 3 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 2 | 2 | 1 | 8 | 50% | P 1 · E 1 |
| media | 0 | 8 | 1 | 1 | 0% | P 8 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 3 | 0% | — |
| search | 5 | 3 | 0 | 0 | 63% | P 2 · R2 1 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **27** | **16** | **13** | **18** | **63%** | P 11 · R2 4 · E 1 |

Exit criterion not met: no leg ran in recovery; act at 63% — under 90%; media at 0% — under 90%; search at 63% — under 90%; context has 2 failing leg(s); 4 page-routing failure(s) on the recorded corpus.

### Round 2 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 6 | 2 | 1 | 5 | 75% | R2 2 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 2 | 2 | 1 | 8 | 50% | P 1 · E 1 |
| media | 4 | 4 | 1 | 1 | 50% | P 1 · E 3 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 3 | 0% | — |
| search | 6 | 2 | 0 | 0 | 75% | P 1 · R2 1 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **33** | **10** | **13** | **18** | **77%** | P 3 · R2 3 · E 4 |

Exit criterion not met: no leg ran in recovery; act at 75% — under 90%; media at 50% — under 90%; search at 75% — under 90%; context has 2 failing leg(s); 3 page-routing failure(s) on the recorded corpus.

### Round 3 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 4 | 4 | 1 | 5 | 50% | R2 4 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 2 | 2 | 1 | 8 | 50% | P 1 · E 1 |
| media | 6 | 2 | 1 | 1 | 75% | P 1 · E 1 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 3 | 0% | — |
| search | 5 | 3 | 0 | 0 | 63% | P 2 · R2 1 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **32** | **11** | **13** | **18** | **74%** | P 4 · R2 5 · E 2 |

Exit criterion not met: no leg ran in recovery; act at 50% — under 90%; media at 75% — under 90%; search at 63% — under 90%; context has 2 failing leg(s); 5 page-routing failure(s) on the recorded corpus.

### Round 4 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 5 | 3 | 1 | 5 | 63% | R2 2 · E 1 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 2 | 2 | 1 | 8 | 50% | P 1 · R2 1 |
| media | 5 | 3 | 1 | 1 | 63% | P 1 · E 2 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 3 | 0% | — |
| search | 6 | 2 | 0 | 0 | 75% | P 2 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **33** | **10** | **13** | **18** | **77%** | P 4 · R2 3 · E 3 |

Exit criterion not met: no leg ran in recovery; act at 63% — under 90%; media at 63% — under 90%; search at 75% — under 90%; context has 2 failing leg(s); 3 page-routing failure(s) on the recorded corpus.

### Round 5 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 5 | 3 | 1 | 5 | 63% | R2 2 · E 1 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 2 | 2 | 1 | 8 | 50% | P 1 · E 1 |
| media | 4 | 4 | 1 | 1 | 50% | P 1 · E 3 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 3 | 0% | — |
| search | 6 | 2 | 0 | 0 | 75% | P 2 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **32** | **11** | **13** | **18** | **74%** | P 4 · R2 2 · E 5 |

Exit criterion not met: no leg ran in recovery; act at 63% — under 90%; media at 50% — under 90%; search at 75% — under 90%; context has 2 failing leg(s); 2 page-routing failure(s) on the recorded corpus.

### Round 6 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 5 | 3 | 1 | 5 | 63% | R2 2 · E 1 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 3 | 1 | 1 | 8 | 75% | P 1 |
| media | 5 | 3 | 1 | 1 | 63% | P 1 · E 2 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 4 | 3 | 0% | — |
| search | 7 | 1 | 0 | 0 | 88% | R2 1 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **35** | **8** | **13** | **18** | **81%** | P 2 · R2 3 · E 3 |

Exit criterion not met: no leg ran in recovery; act at 63% — under 90%; media at 63% — under 90%; search at 88% — under 90%; context has 1 failing leg(s); 3 page-routing failure(s) on the recorded corpus.
