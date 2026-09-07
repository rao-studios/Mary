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

A leg that states only where its words should go is **unmeasured** by the probe,
which routes nothing. Thirteen of them used to pass there, because nothing else
about them could fail, and the live rate counted them as engine work that had
gone well. The turn-level runner answers for them; the probe says so.

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

### Round 7 — a layer for the stage, and three rounds of blaming the wrong one

`act` had sat at 63% since round 4 on two failing legs, both filed as R2 — the
router had the row and did not pick it. Neither was a routing fault, and the reason
nobody had noticed is that **there was no layer for what they actually were.**

- **`check-the-box`** asked a page to "check the box that says remember me". The
  form this machine stages is httpbin's pizza order — E-mail address, Telephone,
  Bacon, Onion. **There is no remember-me box on it.** The engine read the page,
  searched four screens down for it (round 5's work, behaving exactly right),
  found nothing and refused `elementNotFound`. The classifier reported "reached
  nothing, though 27 rows in the reading answer the class" — where the class was
  `named: true`, which every named row answers. The count was vacuous and the
  layer was wrong.
- **`press-by-name`** asked for "news" on a results page that has **two different
  controls called News** — one in the header at 41×40, one in the tab strip at
  81×32. The engine refused `ambiguousElement` and **named both rivals**, which is
  precisely what the refusal ladder exists to produce. That was filed as the
  router missing a row.

`TripFailureLayer.stage` — `X` — is the missing column: the page in front of the
leg was not the page the leg is about. It is the trip's fault or the machine's, a
seed that does not hold what the leg names or a phrase the page wears twice, and
both are fixed by staging. Two rules route to it: a refusal that **named rivals**,
and — only where the class says nothing but `named` — a goal **no row on the page
carries a word of**. A stated class is evidence and is believed: when a leg says
"a video, the first of its kind" and the reading holds a video, a miss is the
router's and the echo test has no business overruling it, because a row can answer
a goal under a name sharing no word with it. That is what the meaning term is for,
and a pinned test says so.

Then the staging itself: `check-the-box` became a keyed leg like `press-by-name`,
so the machine supplies a phrase its own form actually holds, and the leg tests the
SHAPE of the request rather than a label this repository cannot know. Both pass.
`press-by-name` also stopped pinning `lexicalBasis: contained` — a keyed leg cannot
pin a basis, because the phrase is the machine's and whether it matches exactly or
by containment depends on a word this file does not choose.

**`recovery` had never run a leg in seven rounds**, and eight of `context`'s
eleven unstageable legs said the same sentence: *"textedit has to be in front"*.
Bringing a named application forward is what `VerifiedActivation` does for every
act this engine performs — the browser is brought forward by it constantly — so
the runner does it, verified, and only calls the leg unstageable if the activation
does not take. What stays a person's job is unchanged and is the real distinction:
music playing, a hand on the page mid-trip, a second window. Those are states of
the world nobody can synthesize; which application has focus is not one of them.
Unstageable fell from 18 to 15 and `recovery`'s legs now reach their rehearsal.

**The exit criterion said "two consecutive rounds" and measured one.** After
77/72/74 from one build, a criterion satisfied by whichever sample ran last is a
criterion about luck. A scoreboard cannot see the previous round; it can refuse to
call one sample the answer, and it now does.

#### The numbers

Two whole-corpus samples: **82% and 80%**, against round 6's 79 and 81 — the
overall rate did not move, and the ranges overlap. What moved, in both samples and
in the same direction:

| | round 6 | round 7 |
|---|---:|---:|
| `act` | 63% | **88%** |
| R2 failures | 3 | **1** |
| unstageable | 18 | **15** |

The one remaining R2 is a search leg. The three P failures are the media lane on a
file page — "0 controls seen" — which has been a detector question since round 2.

#### What round 8 should take

- **`context` at 50%, and it has never been higher.** Three failing legs, two of
  them P. It is also the category the exit criterion treats most strictly, and the
  one whose invariants the whole plan was written around.
- **`media` at 63%, and the two P failures are the same one.** A player on a file
  page shows no transport to the reading. Filed against VisionAX since round 2 and
  not looked at since.
- **`recovery` still passes nothing**, but for an honest reason now: its legs are
  rehearsals with no binding to dispatch. Either they get one or the category stops
  being counted as a live rate.

### Round 8 — the revision: one stage, the browser as a workspace, journeys

Seven rounds drove the same forty-three legs. The rate went from 30% to 80% and
the layer column moved every round, and the same three numbers never did:
pending legs (13, then 14 — the round-3 verbs were never built), `recovery` legs
run (none), and `context` (50% throughout). Four of the seven rounds were
repairs to the classifier or the runner. The corpus was written from the
engine's own verbs, so the rounds converged on the engine's own verbs; nothing
in it was a journey, and nothing in it was said from another application —
which is how every reported sentence was said. Round 8 is the revision: fix the
four things the corpus could not see, write the corpus that measures them, run
both runners until two consecutive rounds clear 90%, then condense.

#### Part 1 — one stage, and the browser inherits it

"Hey can you pause the video" was answered *Chrome wouldn't come forward.* about
a Chrome that was running. Traced, the stage was fourteen call sites with two
selection rules, three name-to-pid ladders, two frontmost verifiers and six
refusal sentences, and the only code that raises a **window** — window
management's restore-and-`AXRaise` — was used by window management alone.
`VerifiedActivation` activated a **process** once and polled; it never raised a
window, so a window minimized or on another Space was reported forward with
nothing on screen. The browser lane made it worse three ways: its seam answered
`Bool`, so five different reasons reached the person as one sentence; it read
the shell **before** staging, so every pointer act aimed at a page frame
measured while the window could still be behind another; and it restored the
cursor after an act and never the application — "mute the video" said from an
editor left the browser in front, which is invariant 3 broken, designed in
round 1 and never built. And `bring_application_forward`, the window-management
skill itself, was bound to an operation no adapter published.

One faculty now. The ladder resolves a helper to the regular member of its
family (a roster matching a bundle family by prefix hands over renderers, and a
renderer can never be frontmost — measured as an activation that "refused"
forever), activates, and when activation alone does not take within its share
of the budget, **restores and raises the application's main window through
Accessibility** and asks again; a visible window is proved by default. The
result is `Activation`, never `Bool`, and the browser speaks its reason. Eight
copy-pasted guards in the engine became one `staged` door that takes the
`StageArbiter` lease and the self-driving hold every other staging lane already
took, reads the shell **after** the stage is taken, re-checks focus before the
media lane's click, and gives the stage back when the verb answered a question
or drove the player — a verb that changes where the person is looking keeps it.
A search holds the stage once, through the whole journey. The four frontmost
guards in the typer and the chord are one.

Measured live, TextEdit in front and Chrome behind: "Hey can you pause the
video" **landed on `mediaState` in 1.6 s and TextEdit was in front after.**
`window-behind`, unstageable for seven rounds, passes. `window-minimized` — the
runner minimizes the browser's window through the same primitive — passes, and
found a rule on the way: the first raise road preferred any unminimized window,
and on a browser with two the person's other window came forward while the page
asked about stayed in the Dock. **The main window, minimized or not, is the one
the person last worked in.** What this cannot yet answer honestly: which of two
browser windows a sentence means when both are open — that is the per-window
model, and it is still owed.

Also on the way: round 1's shell press was an `AXPress` written into the seams
file, which the machine-layer guard had been failing on all along; it goes
through Hands now, where the monitor can see it.

#### Part 2 — the browser is a workspace

"What's on this page right now on Google Chrome" was answered *You're looking
at whatever webpage is open in your Chrome window right now* — a paraphrase of
the standing brief's own "I have not read this page yet". Traced, the sentence
had four faults stacked under it, none of them the router's. `chrome.mary`
declares a workspace perception and a web surface, and the plugin compiler's
workspace guard admitted prose, code, media and corpus surfaces and did not know
the web surface existed — so every browser compiled **perception-only**: no
eyes, no document channel. The browser workspace is the one place `"browser"`,
which no package registers under that id, so the place had no registration and
everything derived from one — class, eyes, discipline — answered as though no
browser were installed; a place with no discipline can never lead, and naming it
moved nothing. The pre-read keyed on the lead alone, so a page question asked
from an editor read the editor. And the intent was read off the framed sentence:
"Can you click on the first link" classified as a **question** (perceive, 0.69)
while its own words reached `click_on_page` at 0.89, and nothing was dispatched.

Each fixed where it lives. The compiler admits a web surface as a workspace
whose document channel is `page_context` — the shell read, never a pixel and
never an address — and the adapter binds it. The browser workspace is backed by
the browser the ledger evidences, else any package realizing browsing, since
what is asked of a registration there is the same for all of them. The
pre-read takes **the place the sentence named** before the lead — the invariant
`page-question-from-an-editor` had asserted for seven rounds. And the intent is
read off the bare request first, the way round 4 bared the skill read: the bare
form is the request, the frame is how it was asked.

Then the turn-level runs found the fault the probe could not: **from a regular
application that is not active, cooperative activation is ignored.** The probe
is a command-line process and its activations took; the bench is an application
behind an editor, exactly as Mary is when spoken to, and "Chrome didn't come to
the foreground" after the whole budget — the reported sentence, reproduced at
last. A raised window does not activate its process. Setting the application's
own `AXFrontmost` attribute is how an assistive client activates what it drives,
granted to a trusted process whoever is active; it is the raise road's third
step now, and the same sentence from the bench brings Chrome forward.

One more, found the same way. The confidence lane spoke nothing on a success —
"the act was the answer" — so "Can you click the first link on this page"
pressed the link, changed the page, and ended without a word, which is the
shape the person reported as not working. A landed act speaks its receipt now;
silence stays for the act that only changed where the person is looking.

Measured, through the whole turn with TextEdit in front: "Can you click on the
first link" reads as operate on the bare request and dispatches `click_on_page`
with "the first link" on the confidence lane, Chrome forward after, and says
*click "the first link" — the page became Wikimedia Commons*. "What's on
this page right now on Google Chrome" and the dictated correction "No I'm not
what's on this page I'm looking at in Google Chrome" both read as perceive
(0.86, 0.85) and reach `read_page` uniquely. What the voice says on a perceive
turn is the model's, which the bench cannot hear; `aNamedPlaceIsReadBeforeTheLead`
pins that the page, not the editor, is what it is handed. Through the probe with
the browser in front: "Can you click the first link on this page" lands; "Can you
scroll down this page" is delivered in 70 ms and says so.

#### Part 3 — the arguments a lane can carry

"Can you go back two minutes in the video" ran nothing, and "Can you go to three
minutes in the video" was answered *I couldn't work out how to do that*. The seek
took a fraction and nothing else, so a person had to know the video's length and
divide; `position` was an optional string, which the no-model lane could not fill
by construction — it fills one required string, the enums a sentence names, and
the application — so every seek cost a model round; and `navigate_back`'s corpus
is "Go back", a zero-argument verb one short sentence away from leaving the page.
"Can you go to youtube.com" was refused as *guessing at that address*: the gate
read a missing scheme as missing provenance, about a host the person had said.

Three generic rules. A parameter the package marks `spokenSpan` receives the
sentence's remaining span, the same peel the required string gets, so "go back
two minutes in the video" dispatches with `action: seek` and the time in hand.
`SpokenDuration` is the closed English vocabulary of lengths of time — "two
minutes", "thirty seconds", "a minute and a half", "1:30" — and which way they
point, on the same side of the doctrine as "third"; a number without a unit is
not a time. And a bare host the person said is admitted with the scheme every
front door has: the rule is provenance, not spelling.

A time is a place on the track once the video's length is known, and the lane
that knows it turned out not to be the one that draws it. MEASURED on the staged
watch page: the picture lane finds the bar on one look and loses it on the next,
because a player hides its bar on a timer, and the bar it finds is a rectangle a
click on which moves nothing — it reported 0.6% for a video at 3:10 of 10:34.
The page publishes the same bar as `slider "Progress Bar" 879×5, value 0.5 in
0…100, settable`, a role and a range, for as long as it is drawn, and a click on
that rectangle moves the video exactly. So a seek takes the page's own slider as
the track when one is published, reads the position off the transport's clock —
text the reading OCRs, and right — and the pixel bar is the last resort. Rows
carry a control's value and range through the seal now, and so do recordings.

Live, the video playing: "seek to 1:30" → *Went to 1:30 — Playing, 1:31 of
10:34*; "seek back two minutes" → *Went back 2:00 — Playing, 0:01 of 10:34*.
Both trips land on `mediaState` through the probe; through the whole turn the
sentence reads as operate on the bare request, reaches `control_media` uniquely
(0.92), and fills `position` with its own words. "Go to youtube.com" is a
navigation receipt in 1.1 s. One finding filed against the picture lane: on one
run the clock's OCR read 10:34 as 1:40, and "three minutes" clamped to the end of
a video the reading believed was shorter — a destination past the end refuses and
names the length now, which is right whether the video or the reading is short.

#### Part 3b — the verbs the corpus waited five rounds for

Thirteen legs had sat `pending: round 3` since the corpus was written, and the
verbs they name were never built: switch a tab, close one, find a word on the
page. The census had already measured what happens without them — "find the word
budget on this page" reached `reload_page` at 0.70 on the confidence lane, which
would have reloaded the page instead.

`switch_tab` presses the tab the browser publishes, by title, by position, or as
"the other one". A tab is a control with the page's name on it, found by the same
shell walk that finds Back; a chord would count tabs the browser's way, and a
person counts them the way they see them. Proved by the shell: the window wears
the tab's name. `find_in_page` opens the browser's own find bar — a chord the
package declares, aimed at the browser — and types into it; delivered, not
landed, because what the bar found is drawn in the shell and this lane does not
read it back. `close_tab` is Command-W through the browser's package, like the
new tab beside it, and it is a **write**: the turn asks first, and the tab count
does not move until somebody answers.

Two rules came out of driving them. A page title is punctuated and a person is
not — the title matcher folds punctuation AWAY rather than to a space, right for
a song called "Rock & Roll" and wrong for a tab called "about:blank", which
becomes one token nobody can say; every tab is spoken as its words before it is
matched. And an act speaks its receipt: the confidence lane said nothing on a
success, so "find the word budget" opened the find bar in 409 ms and the turn
ended silent, which is the shape the person reported as not working.

Three defects the driving found that no test would have:

- **A panel can be the main window, and then every read is about the panel.**
  After a find, Chrome's find bar is its own accessibility window and takes
  `AXMain` — so the shell reported the page's title as "Find in page", published
  no tabs at all, and every later read in the turn was about a strip forty points
  tall. A browsing window is the one with the browser's own furniture in it: a
  toolbar, or the page. Told apart by shape, never by a title.
- **A stage is a state, not a gesture.** The two-tab staging pressed the new-tab
  chord every run, and six runs left six tabs — three called the same thing, so
  "the blank tab" was genuinely ambiguous and the leg's refusal was correct about
  a window nobody meant to build. It opens a tab only when there are fewer than
  two, and the trip begins on the page it is about.
- **Closing the only tab closes the WINDOW.** The close-tab leg did exactly that,
  and the browser then resolved to the person's own window — measured, and the
  reason that leg is staged with a second tab now.

The clock is the probe's, not the turn's: a find that took 409 ms through the
engine took 44 seconds through a turn that spends most of itself in a language
model, and was reported as a timing failure of a verb that had already answered.

And **"skip the ad" needs no verb.** A small pressable row drawn inside the
picture is an overlay by geometry — the same fact a consent wall's button
carries — so the seal marks it and the router's existing overlay credit does the
rest, through `click_on_page` with the person's own words. The rule is pinned in
tests; the leg is `pending` a staged page whose player actually shows an ad,
because a leg expecting an overlay press on a page with no overlay would measure
the seed rather than the router.

#### Part 4 — a journey, and the site a person named

"OK can we watch Fred again video on YouTube" searched and listed results, and
the corpus had asked the same thing in round 0: `search_web`'s `open` was an
optional string no lane could fill, so a sentence that names both WHAT and WHERE
could only ever be half answered. Nothing in the lane weighed where a result
went.

A row's own link is the missing fact. The accessibility lane already reads it;
the seal now turns it into the SITE, as a person would say it — a name, never an
address, so a recording still holds no URLs. What makes "youtube" a site is that
a row on THIS page leads to one by that name: the page vouches for the word and
nothing in the repository holds a list of sites.

**A site is a gate, not a credit** — the rule a place already keeps, for the same
measured reason. First it was a ranking term, and the naming ladder is compared
before the structure: a related-search suggestion literally spelled "youtube
fireplace 24 hours" outranked every actual YouTube result and the journey opened
another results page. A person who says where has narrowed the page.

`watch_video` is the first journey: several verbs said as one sentence, deciding
from the reading rather than from a plan. It searches, arbitrates the results for
what and where together, and — when no result goes to the site they named — opens
that site's own row and uses its search box, which is `site-search`'s machinery.
Nothing in it presses or types by itself; every step is a verb that already
refuses by name and records its own route. The trip grammar gained a `journey`
block and the classifier a **J** layer: a journey is judged on its SEQUENCE, and
every step underneath it may be right.

Three defects the driving found, each older than the journey:

- **A roster rebuilt from `elements` loses what only a row carries.** The
  AX-shaped pair is kept for the callers that still read it, and a row's site,
  its slider range and its provenance are not in it — so the recipe handed the
  router a page whose results all went nowhere in particular, and the site gate
  had nothing to gate on. The engine publishes the real rows a moment earlier;
  they are what the route is argued from now.
- **A search whose results are already in front has arrived.** Running the same
  journey twice typed the query into a browser already showing that query's
  results, nothing changed because nothing could, and the whole navigation budget
  was spent before reporting "the page didn't finish loading". This is `settle`'s
  own arrival rule one level up, proved by the same evidence.
- **Two rows that lead to the same place under the same name are one answer.**
  A search engine prints its top video twice, in a carousel and in the list, and
  Mary asked which of the two identical rows the person meant. "A tie is a
  question, not a coin flip" is about rivals; these are not rivals. The trace
  says so too, rather than recording a clarification nobody was asked for.

Live, from a blank page: *watch a fireplace video on youtube* → the results, the
YouTube result chosen over the suggestion that merely says "youtube", the watch
page open, and `describe_media` reporting **"Playing, 0:00 of 1:25."** — 8.4 s
end to end. The dictated sentence reaches the journey too. What the corpus
change cost, and it is worth naming: three sentences that used to be `search_web`
now name the journey, because "find me a clip on youtube" is not a request to see
a list; and the transport needed fixtures of its own — "mute the video", "play
the video" — to keep the sentences that ARE about the player.

**"Skip the ad" still has no live leg.** A pressable row drawn inside the picture
is an overlay by geometry now, which the router already credits, and the rule is
pinned in tests — but the seeded watch page shows no ad, and a leg asserting an
overlay press on a page with no overlay would measure the seed rather than the
router.

#### The browser's own question

A screenshot after part 4: Chrome's "Confirm Form Resubmission" — *The page
that you're looking for used information that you entered … Cancel /
Continue* — standing over a page, and Mary reporting the reload beneath it as
done. Reproduced on the trips window with the `form` seed: submit, then
`--navigate reload`. The engine said *Reloaded httpbin.org/post* and a read
listed the page's rows under the dialog.

**Measured.** The dialog is not a window. Chrome publishes it INSIDE the
browsing window as an `AXGroup` with the `AXApplicationDialog` subrole — a
heading, a static text and two `AXButton`s, left to right — so
`browsingWindow` still found the page's window, the tabs and the toolbar were
where they always are, and nothing in the shell read said the page could not
be seen.

**The system**, in the layers that own it:

- **The shell reads it.** `WebSurfaceAX.Reading.dialog` — title, body and the
  choices as labelled, from the modal subroles an assistive client knows
  (`AXApplicationDialog`, `AXSheet`, …). Platform vocabulary, no site's.
- **Every verb has a stance.** `staged(_:after:asking:)` reads the shell after
  the stage is taken and, when a dialog is up, does one of three things. The
  default is to STOP with the browser's own question and its choices
  (`BrowserRefusal.browserIsAsking`). A read DESCRIBES it — "what's on this
  page" is answered with the question, never with the rows behind it. A press
  can ANSWER it, and only a press.
- **A settle that sees the question reports it.** A reload that raises the
  dialog is not "Reloaded" and not a stall: the poll that sees the dialog
  returns it as the outcome.
- **The person's words answer it, never a default.** `click_on_page` whose
  words carry one choice, as whole words — "press cancel", "continue the
  video" — sends that button its own action through the shell press; the
  receipt is the dialog gone from the next reading (`dialogAnswered`).
  Words that name no choice, or "yes", put the question back. "Continue" on a
  resubmission is a write the person did once already, and it is theirs to say.
- **The brief says so first.** `page_context` and the awareness brief carry the
  question ahead of the page, with the choices as the vocabulary.

**Trip.** `recovery/browser-is-asking`, staged by the runner: the `form` seed
submitted by the `formSubmit` phrase, reloaded, and the engine's report of the
question is the stage. Three legs, live on the first run after the refusal was
named for the probe:

| Said | Layer | Result |
|---|---|---|
| "scroll down this page" | E | refused `browserIsAsking`, nothing scrolled, 240 ms |
| "what's on this page" | E | spoken: the question and its two choices, 227 ms |
| "press cancel" | E | `dialogAnswered`, dialog gone, 711 ms |

Sand marks this stage — with a playing video, a second tab and a minimized
window — as the probe's to make rather than running the turn against a stage
nobody set.

**Found on the way.** `--score --write` replaced this whole narrative with the
round's table: it matched any heading beginning "### Round 8 — ", and the
narrative was headed "### Round 8 — the revision". The writer now rewrites only
a heading with its own date after the dash.

### Round 9 — the browser's own question, and three rules the corpus had been paying for

Round 8's table stood at 74% with eleven failing legs, most of them not
regressions but three standing faults the recordings had been carrying since
round 7, and one fault round 8 itself introduced.

#### What round 8 introduced

**A shortcut that skipped the typing took a shop for the results.** Part 4
added a standing-shell read before a search — "if the results are already in
front, do not type the query again" — and judged "already in front" with
`searched(for:shell:)`, the check made AFTER typing, where the address is
known to be a search. Asked of whatever page was in front it is far too loose:
a product page titled with two of the query's three words counted as its
results, and "search the web for alpine touring boots" typed nothing and
reported a shop. Two rules now: the shortcut fires only for a query THIS ENGINE
put in front (`lastResultQuery`), and a query typed into a browser already
showing it is a quiet ARRIVAL for the settle rather than a stall — typed all the
same, proved by quiet, never by a title's words. An address keeps the old rule;
the fake-clock stall test caught the first draft treating one as a query.

#### What had been standing since round 7

- **"The third link" counted the header, a skip-link and the right column.**
  `countsForAPosition` skipped furniture by FACTS — a toolbar, a form, a band —
  and the site's logo link, its skip-link and its related-search chips carried
  none. They carried a REGION. Positions now count only the page's own column
  (`main`, or an overlay); a header and a sidebar are places a person names and
  never counts. Offline, on the captured page: row 36, the third link in the
  content, where row 26 (a static "Sponsored" heading) and row 31 (a chip on
  the right) had been reached.
- **"The first one" was a static text.** On a site's own search page the pixel
  lane called the search-options panel a list, so "Search in: (Article) ×" was
  in a result group and was the first one. A result is something that OPENS:
  the `.openResult` count now needs `inResultGroup` AND a press affordance.
  The same page still has no real first result the seal can count — its result
  entries were grouped as bands across columns — which stays filed against the
  seal's grouping, and the rule at least no longer answers with prose.
- **Recorded routes drift on purpose.** Five recorded legs answer differently
  against their own reads after the two counting rules, which is what the
  replay net is for; round 9's recordings replace them.

#### The browser's own question

Built between the rounds from a screenshot — see the section under round 8.
`recovery/browser-is-asking` runs in every round from here on.

#### What round 9 measured: the lane was working in the person's window

Round 9 ran at 73% and the tab legs fell to 33%, and the recordings said why
in one line: "go to the second tab" pressed a tab and the window became *The
Final Industry - Miro* — a tab in the person's own window. The shell read
lists the tabs of "the browsing window"; the press walked the whole
application for a tab of that name; the raise road raised the application's
**main** window. Chrome's main window is whichever window the person last
clicked. So from the moment they touched their own window, every read, press
and raise the round made went there: trips opened tabs in it, staged a second
tab in it, and played a video in it while they were reading.

**The fix is an identity, not a rule about "main".** `AXWindowIdentity` names
a window by its window-server id, asked of the element itself
(`_AXUIElementGetWindow`) and stamped on every `AXWindowSnapshot` at capture
— the origin-and-size guess that was there before named the wrong one, because
every window a round opens sits at the same origin as the last. The engine
remembers the window of its last shell read (`workingWindow`) and asks for it
on every read (`preferring:`), every shell press (`within:`) and every raise
(`raising:`); the seams carry it with default forwarding so the fakes are
untouched. A runner that opened the window names it: the probe takes
`--window <id>`, `--front-window` prints the id of the window just opened,
and the round script names the round's window once and hands it to every trip.

Proved in a fresh window after the fix: the named window was the one read
(one tab, about:blank), the tab trips passed in it, and after them it held
exactly the two tabs the trips made. The person's window was not read.

**Also found.** "Play it from the start" on a player nobody has started —
a poster, one play circle, a duration badge, no bar until the first play —
refused "not its progress control". Pressing play is playing it from the
start; the seek to the beginning with no track and a centre glyph is a play.

### Round 10 — the round's window closed, and everything after ran in the person's

Round 10 was the first round in a named window and scored 82% — the best
yet — and its recordings still carried the same fault as round 9 in a new
form: the window the script had named closed partway through, every read
after it fell back to the browser's main window, and that window was the
person's. Chrome's "main" is whichever window was clicked last; a fallback
to it is a fallback into somebody's reading.

**A pinned window, or nothing.** `adopt(window:)` now pins: a shell read
that comes back about any other window is `workingWindowGone`, a refusal,
never a new working window. And a named window that is not the front one is
not "already forward" — the raise road runs and raises it, because an
application in front with the wrong window on top is exactly how ⌘L went
into the person's omnibox. The address open reads its typing back from the
working window (it read the main window's field and said "I couldn't find
the address bar" about a field it had just typed into). Sand takes
`--window` too; the probe can close a window it opened
(`--close-window`), and the round script closes its own at the end.

**The clock, from the page's own rows.** Three seconds into a video the OCR
made out only "10:34", or nothing — the elapsed sits in a highlighted box —
and a seek refused "I can't tell how long the video is" with the length on
screen. The elements read the slider lookup already makes carries "Current
Time 0:22" and "Duration 10:34" as text, so the clock is taken from the rows
beside the bar before the pixels; and one lone time with the track's fraction
is a whole clock (at the start it is the length; further in, the division).

**A strip is furniture.** "The first link on this page" reached "Article" —
the page's own tab, which does nothing. A row of pressables on one baseline,
in one region, most of them named too shortly to be answers, is a strip
(`RowFactsDerivation.strips`), whether or not the reading grouped it.

**A blank tab, not merely a second one.** The two-tab stage counted a window
that earlier trips had left with two pages as staged, and "switch to the
blank tab" found no blank tab.

Proved live in a fresh pinned window before round 11: the two first-link
legs, the blank-tab leg, both seeks and "play it from the start" all pass;
a read against a window that is gone refuses by name; the person's window
was not read.

### Round 8 — 2026-09-07

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 7 | 1 | 0 | 5 | 88% | E 1 |
| arrive | 6 | 2 | 0 | 1 | 75% | E 2 |
| context | 0 | 0 | 0 | 17 | 0% | — |
| journey | 1 | 1 | 0 | 0 | 50% | J 1 |
| media | 7 | 3 | 2 | 1 | 70% | P 1 · E 2 |
| read | 1 | 0 | 0 | 6 | 100% | — |
| recovery | 2 | 0 | 3 | 3 | 100% | — |
| search | 5 | 3 | 0 | 0 | 63% | R2 1 · E 2 |
| tabs | 2 | 1 | 2 | 1 | 67% | E 1 |
| **all** | **31** | **11** | **7** | **34** | **74%** | P 1 · R2 1 · J 1 · E 8 |

Exit criterion not met: no leg ran in context; act at 88% — under 90%; arrive at 75% — under 90%; journey at 50% — under 90%; media at 70% — under 90%; search at 63% — under 90%; tabs at 67% — under 90%; 1 page-routing failure(s) on the recorded corpus.

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

### Round 7 — 2026-09-06

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 7 | 1 | 1 | 5 | 88% | E 1 |
| arrive | 7 | 0 | 0 | 1 | 100% | — |
| context | 3 | 3 | 1 | 6 | 50% | P 2 · E 1 |
| media | 5 | 3 | 1 | 1 | 63% | P 1 · E 2 |
| read | 6 | 0 | 1 | 0 | 100% | — |
| recovery | 0 | 0 | 5 | 2 | 0% | — |
| search | 6 | 2 | 0 | 0 | 75% | R2 1 · E 1 |
| tabs | 2 | 0 | 5 | 0 | 100% | — |
| **all** | **36** | **9** | **14** | **15** | **80%** | P 3 · R2 1 · E 5 |

Exit criterion not met: no leg ran in recovery; act at 88% — under 90%; media at 63% — under 90%; search at 75% — under 90%; context has 3 failing leg(s); 1 page-routing failure(s) on the recorded corpus.

### Round 9 — 2026-09-07

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 6 | 2 | 0 | 5 | 75% | R2 2 |
| arrive | 8 | 0 | 0 | 1 | 100% | — |
| context | 1 | 1 | 0 | 13 | 50% | R2 1 |
| journey | 2 | 0 | 0 | 0 | 100% | — |
| media | 6 | 4 | 2 | 1 | 60% | P 1 · E 3 |
| read | 1 | 0 | 0 | 6 | 100% | — |
| recovery | 1 | 1 | 3 | 6 | 50% | P 1 |
| search | 6 | 2 | 0 | 0 | 75% | R2 2 |
| tabs | 1 | 2 | 2 | 1 | 33% | E 2 |
| **all** | **32** | **12** | **7** | **33** | **73%** | P 2 · R2 5 · E 5 |

Exit criterion not met: act at 75% — under 90%; media at 60% — under 90%; recovery at 50% — under 90%; search at 75% — under 90%; tabs at 33% — under 90%; context has 1 failing leg(s); 5 page-routing failure(s) on the recorded corpus.

### Round 10 — 2026-09-07

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 7 | 1 | 0 | 5 | 88% | E 1 |
| arrive | 8 | 0 | 0 | 1 | 100% | — |
| context | 1 | 1 | 0 | 13 | 50% | E 1 |
| journey | 2 | 0 | 0 | 0 | 100% | — |
| media | 7 | 3 | 2 | 1 | 70% | E 3 |
| read | 1 | 0 | 0 | 6 | 100% | — |
| recovery | 2 | 0 | 3 | 6 | 100% | — |
| search | 6 | 2 | 0 | 0 | 75% | P 2 |
| tabs | 2 | 1 | 2 | 1 | 67% | E 1 |
| **all** | **36** | **8** | **7** | **33** | **82%** | P 2 · E 6 |

Exit criterion not met: act at 88% — under 90%; media at 70% — under 90%; search at 75% — under 90%; tabs at 67% — under 90%; context has 1 failing leg(s).

### Round 11 — 2026-09-07

| Category | Passed | Failed | Pending | Unstageable | Rate | Layers |
|---|---:|---:|---:|---:|---:|---|
| act | 4 | 0 | 0 | 11 | 100% | — |
| arrive | 0 | 8 | 0 | 1 | 0% | E 8 |
| context | 0 | 0 | 0 | 17 | 0% | — |
| journey | 0 | 2 | 0 | 0 | 0% | J 2 |
| media | 0 | 0 | 0 | 13 | 0% | — |
| read | 1 | 0 | 0 | 6 | 100% | — |
| recovery | 0 | 0 | 4 | 7 | 0% | — |
| search | 0 | 4 | 0 | 4 | 0% | R2 1 · E 3 |
| tabs | 1 | 0 | 1 | 4 | 100% | — |
| **all** | **6** | **14** | **5** | **63** | **30%** | R2 1 · J 2 · E 11 |

Exit criterion not met: 63 leg(s) unstageable against 20 that ran — stage the machine before reading this table; no leg ran in context, media, recovery; arrive at 0% — under 90%; journey at 0% — under 90%; search at 0% — under 90%; 1 page-routing failure(s) on the recorded corpus.
