# The browser engine

Mary drives a browser in two halves, and the split is the whole design.

**The browser's own controls come from Accessibility.** Its address field, its tab
strip, its back and forward buttons are native views that every browser publishes
properly. Reading them is cheap, exact, and needs no pixels.

**What is inside the page comes from sight.** A rendered page is where Accessibility is
either lossy or absent — Safari publishes a rich tree, Chromium publishes nothing at all
until an assistive client wakes it, and a video player publishes almost nothing either
way. So the page is captured and read by [VisionAX](../../VisionAX), which turns pixels
into regions, roles, text and a media transport.

The base case is a video on a watch page: find the player's own controls in the picture,
click the one that does what was asked, and prove it landed by looking again.

## What it does not do

Three shortcuts would each have been easier, and each is refused by a test
(`Tests/MaryPluginTests/NoSiteShortcutsTests.swift`):

- **A site's own keyboard shortcuts.** `k` pauses a video on one site, types a letter
  into a comment box on the same page, and means nothing on the next site.
- **The system media keys.** They reach whatever process holds the now-playing role. On
  a machine with a music player open, that is not the tab anyone is looking at.
- **Scripting the browser.** It skips the page entirely, and only one browser answers —
  which is the split this design exists to remove.

A URL is **held, never spoken**: every summary names the site ("youtube"), because an
address read aloud is unusable as speech and puts query strings into a transcript.

## The pieces

| Where | What |
|---|---|
| `Abilities/browsing.mary` | The discipline: ten skills, the capabilities they need, and the page-context perception. It names no application. |
| `Abilities/safari.mary`, `Abilities/chrome.mary` | The expertises. Each declares a `webSurface` block — the labels ITS browser uses — and realizes a browsing skill, which is what gives its profile the `browsing` ability. |
| `Sources/MaryFoundation/Plugins/PluginWebSurfaceSchema.swift` | The grammar of that block. |
| `Sources/MaryPlugin/WebSurface/` | `WebSurfaceRegistration` / `WebSurfaceSupport` (which browser), `WebSurfaceAX` (the shell), `BrowserEngine` (the turn), `WebSurfaceAdapter` (the skills), `SiteName`, `BrowserTargetResolution`. |
| `Sources/MaryComputerUse/Sight/Vision/` | `VisionPageReader` (the only file that imports VisionAX), `MediaControlReading`, `PagePerceptionPipeline`. |
| `Sources/MaryComputerUse/Sight/WindowPixels.swift` | The one ScreenCaptureKit path, with a MEASURED scale. |
| `Sources/Probes/WebProbe/` | `mary-web-probe` — the live instrument. |

Nothing in Swift names a browser. The adapter learns that one browser calls its back
button "Go back" and another says "Back" because the packages said so.

## The stages

**Stage 1 — the shell, through Accessibility.** Done. Title, site, tabs, history state,
the window's capture id, and *where the page is*: Safari publishes an `AXWebArea` (whose
frame is the whole scrollable document, so it is clipped to the window), Chromium
publishes none, so its page is what lies under the lowest toolbar. Both rules are
declared per browser and pinned in `WebSurfaceTests`.

**Stage 2 — the page and its player, through sight.** Done. Two captures a fifth of a
second apart go to VisionAX, which returns the transport: the progress track, the row of
controls, which glyph each one is, and three independent witnesses for whether the video
is playing (the picture moved, the progress advanced, the clock advanced). The engine
clicks the control and re-perceives to prove the state moved.

**Stage 3 — Accessibility page-element extraction.** DEFERRED. See below.

**Stage 4 — the page map, and one grammar over it.** Done. VisionAX assembles the page
into rows that can be acted on, grouped and in reading order, and Mary resolves a phrase
against them with the same ladder every other surface uses, acts through one executor,
and proves the effect by looking again. See below.

## Stage 4 — the page map, and one grammar over it

The problem this solves is not "press a button on a page". It is that every *other*
interaction — a search box, the first result, a video, a volume slider, a consent wall —
would otherwise be one more condition in the web-surface layer, and the layer would grow
a rule per site per widget forever.

### What VisionAX hands over

A **page map**: rows, each with a frame, a role, what it affords (press, fill, adjust,
scroll), a label, and *where that label came from*. Built from three sources joined
before anything is classified:

| Source | What it contributes |
|---|---|
| Canny regions | Boxes with an edge — buttons, fields, cards, images |
| **Text lines** | Boxes with no edge at all — a result title is an anchor around a heading, invisible to an edge detector and perfectly legible to recognition |
| Geometry | Which of those rows belong together, and in what order |

The text-line union is the change that matters most. It runs in `perceive` *before* the
classifier, and at harvest time through the same function (`TextLines.proposals`), so the
model is trained on the proposals it will be asked about.

**Grouping is geometry, never markup.** Bands of boxes that share a line, merged with
whatever sits close under them, then compared with their neighbours: a run of similar
bands at a regular pitch is a list, and that is what makes "the first result" mean
anything. Cards, forms, toolbars and overlays fall out of the same pass. A dialog — a box
inset from every edge holding several things to press — is reported first, because
nothing behind it can be reached while it is up.

**Every row keeps a name, and says where it got it.** Classifier label, then words inside
the box, then the label beside it (fields only — a button labels itself), then a drawn
icon, then `"button 3"`. Nothing is dropped for lacking a name, which is what the old
roster did and why a page of search results read as four chrome buttons.

### One router over it

Every verb asks the same question of a page — which row does this goal reach — so it is
asked in one place. `PageRouter.arbitrate(goal:verb:roster:store:)` is the page's answer to
`AbilityRosterArbitrator`: a pure function of one read, giving **every row** a disposition,
a bounded evidence score and one sentence saying why.

| Term | What it is |
|---|---|
| lexical | the naming ladder's rung — ordinal 500, exact 400, contained 300, all-words 200, kind-only 100 |
| semantic | cosine against the goal over the slate this read published, ×1000 |
| affordance | how well the row's affordance fits the verb |
| provenance | how sure the reading is — label source, affordance source, and the reader's own confidence |
| structure | what the row's place says: a result group counts for, a toolbar, a dialog it sits behind, or a "sponsored" marker count against |

They are compared **in that order**, not summed: no pile of small priors can outweigh the
person having said the row's name. A tie is a question, named back. Nothing is decided by
page order unless the person spoke a position.

Three call sites, one arbitration: `PageActor.route` for press / fill / adjust, the same for
`scroll_to_on_page` (`reveal`), and `WebSearchRecipe` for opening a result. What each turned
down is on `BrowserEngineSnapshot.lastRoute`, on the `routed` event, in Sand's **Page route**
pane, and in `mary-web-probe --route`.

**A row the map named but did not offer is a candidate**, published to the slate with its own
capability so the deterministic `act_on_screen` rung can never reach one. A candidate must
clear a higher floor than a row the reading vouched for.

### What Mary does with it

One resolver, one executor, six verbs and a grammar:

- `read_page` lists what is there, numbered *within its kind* — the same counting the
  resolver uses, so what is spoken is what resolves.
- `click_on_page`, `fill_in_page`, `scroll_to_on_page`, `adjust_on_page` each build a
  one-command plan.
- `search_web` types the query into the browser's own address bar, so it uses whichever
  search the person set up, and no address is written for them.
- `interact_with_page` takes a bounded JSON plan for sequences that genuinely belong
  together.

All of them go through `PageActor`, which re-reads the page before every command,
resolves the phrase with `ScreenElementResolver` and then the embedding gate over the
slate that read just published, acts, restores the pointer, and judges the effect.

### Receipts, ranked

`landed` is set only by the top three. A page repaints on its own, so "the rows differ"
is a sign and never proof.

| Rank | Evidence | Lands? |
|---|---|---|
| 1 | The browser went somewhere and stayed | yes |
| 2 | The target itself changed, or is gone | yes |
| 3 | The typed text is in the field | yes |
| 4 | The page's rows differ (tooltips near the pointer excluded) | no — "the page changed" |
| 5 | Nothing | no — delivered, effect unverified |

### The grammar's bounds

Sixteen commands, 32 KiB, targets under 512 bytes, text under 4 KiB, scroll ±2000, waits
under two seconds, one to three clicks, an event budget of 4096, no plan ending on a
hover, and **keys limited to return, escape and tab**. A modified chord inside a page is
a browser command and an unmodified letter is a site shortcut; both are what this
discipline exists not to use, and the validator enforces on model-authored plans what
`NoSiteShortcutsTests` enforces on the source.

### What was measured

Proposal recall — the ceiling on everything downstream, since a box nobody proposed can
never be named or pressed:

| Corpus | Canny alone | With text lines |
|---|---|---|
| Synthetic pages (2,000) | 75.7% | 83.5% |
| Real pages (150 harvested samples) | 62.1% | 72.7% |

List rows went from **0 of 1,736 matched** to 2,207 proposals in the corpus, because a
list item that holds something to press is now emitted as `AXRow` ground truth.

Offering one word-level proposal per text RUN as well as per line was tried and thrown
away: it moved real recall from 0.727 to 0.728 for roughly twice the proposals.

Three defects only a live page could show, each fixed:

- **813 "actionable" rows on one watch page.** Every unnamed box in a row of unnamed
  boxes was being offered as pressable, and hundreds of them were 8×8 fragments of
  letterforms. A box now has to be at least 16 points on both sides, and an unnamed one
  is only pressable when the icon bank recognized the shape drawn in it.
- **Fast text recognition returned nine runs for a whole page**, spelled "Sub8cribe" and
  "23M vlew8". The page lane now reads accurately; the media clock keeps the fast pass,
  where the strip is magnified first and the answer is four digits.
- **The icon bank named two dozen patches of video picture.** The floor moved from 0.55
  to 0.72, which sits above picture noise and below every icon the fixture draws.

### Two the media lane had been hiding

Driving a live player turned up defects the fixtures could not, because both depend on a
crop of a real window:

- **A shape cut off by the crop's edge was being read as the transport.** The left edge
  sliced the player's chrome into a 31-pixel fragment at x=0 which matched `pause` at
  0.45 — enough to become the leftmost control, and therefore the transport, while the
  real play button sat 25 pixels along matching `play` at 0.72. Everything downstream
  then reasoned from the fragment: the reading said "playing" about a paused video, and a
  press that had actually worked was reported as having done nothing. Controls touching
  the frame's edge are now rejected — a shape that is cut off is not a shape.
- **The volume slider was verified with the pointer in the wrong place.** Its track exists
  only while the pointer is on the volume control, so the second look — taken with the
  pointer back over the middle of the picture, which is what keeps a transport visible —
  found some other thin run and reported the progress bar's fraction as the volume. The
  volume act now holds the pointer on its own control for the second look.

### Verified live

On Safari, driven only by `mary-web-probe`:

- Typing a query into the address bar reached the person's own search engine, and the
  settled address was checked against the query as evidence and never spoken.
- A results page read as 89 rows, 81 of them carrying a name something had written,
  19 pressable, in reading order.
- `--click "languages"` resolved the phrase, pressed it, and proved the effect by the
  control's own label changing.
- A four-step plan — click the search control, wait, type "ski mountaineering", submit —
  ran with a receipt per step and ended on the page it asked for.
- Playback toggled and was put back, each direction proved by re-perceiving, and the
  volume was set to 35% and verified against the track's own fill.
- The same acts on **Chrome**: a page read, a control pressed by name and proved, and a
  web search that opened a real result.

### Two the live search found

- **Both omniboxes finish your sentence.** "swift concurrency" typed into Chrome opened
  YouTube, because a history entry was inline-completed and Return accepted it. The
  receipt caught it — `searchCompletedElsewhere`, refused rather than reported as a
  search — and the lane now presses forward-delete before Return, which removes a
  selected completion and does nothing when there is none.
- **A results page shows you your own query, in its own search box.** That row is
  pressable, well named and the right length, so it looked exactly like the top result
  and got opened. A real title contains the query and says more; the echo says the query
  and stops, so what is left after removing it is the test.

### What three recorded pages measured

`mary-web-probe --save-roster` writes a read to JSON; `--fixture … --route "…"` argues with
it offline, with no browser and no grant. Three real pages, recorded and pinned in
`Tests/MaryPluginTests/Fixtures/PageRoutes/`:

| Page | Rows | Offered | What the reading held |
|---|---|---|---|
| A search engine's web results | 80 | 5 | a region picker, a navigation strip, thirteen related searches, the query echoed twice — and the real titles **broken across rows** |
| A video site's own results | 142 | — | a sponsored card, a knowledge panel, a channel line, and not one video title |
| The same site's video tab | 34 | 3 | two real titles, both reachable |

So the router refuses the first two and says, per row, which kind of thing each was. That is
the honest answer: widening the pool and ranking it was tried three ways — page order took
the navigation strip, query-word cover took "Searches related to …", and admitting bands
took the region picker. **A pool nothing vouches for is not a weaker pool; it is a different
page from the one the person is looking at.** The recall belongs in the detector.

Two rules came out of the same measurements and are pinned as tests:

- **A row that is several short names joined by separators is a strip**, not an answer — the
  site's own tabs, drawn as one row, long and well named.
- **An ordinal naming a kind the page holds none of is a miss.** "The first video" used to
  count the rows at large and answer with the first of them; on a page with no video rows it
  now reaches nothing.

And one measurement worth keeping for whoever tunes the floors: asked for "the search box",
Apple's `NLEmbedding` scored the site's actual search field **0.548** and a row called
"Camera lens" **0.544**. Four thousandths apart. No threshold rescues that, which is why
meaning sits *after* naming in the rank vector rather than replacing it.

### What is still weak

- Icon naming is a bank of twenty-two drawn silhouettes compared by blurred correlation.
  It is a fallback rung: an unnamed icon is still "button 4" and still pressable.
- A slider read from pixels has no value and no step, only a track — so `adjust` supports
  minimum, maximum and a fraction, and nothing else.
- Orientation for a track is inferred from its aspect ratio. Stated in the receipt as the
  guess it is.
- **The classifier used to call body text `AXLink`** — a dozen sentences offered as
  links on any article. It had been trained before text lines were proposals, so it had
  never been asked about one. Retrained on the expanded corpus its link precision went
  from 0.49 to 0.941, and that article page went from 16 pressable rows to 3 real
  controls. The trade was recall: some genuine controls stopped being named at all, which
  is why the resolver now reaches past what the map offers when a person names something
  exactly. Numbers in VisionAX's README.
- A field whose border the detector never finds cannot be filled by name. The generic
  answer already works: press the control that opens it, then type where the focus is,
  which is one plan and needs nothing site-specific.

## Stage 3, and why it is not here yet

The seam is `PageReaderLane` in
`Sources/MaryComputerUse/Sight/Vision/PagePerceptionPipeline.swift`, and the work is
written down there as `TODO(browser-stage-3)`. The browser engine asks the *pipeline*,
never the reader, so adding the lane is one enum case and one function body rather than a
change at every call site.

| Now | Then |
|---|---|
| The page's elements come from pixels: measured frames, classifier roles, no labels. | An Accessibility walk of the web area publishes real labels and live handles, merged with the vision roster by frame overlap (IoU ≥ 0.6 wins). |
| A row can be clicked at a point. | A row can be *pressed by name*, and a press has a receipt from the element itself. |
| Chromium's page is invisible to Accessibility. | The wake is sent and the tree arrives. |

**Cost.** The walk itself already exists —
`Sources/MaryComputerUse/Sight/PageElementReader.swift` is a complete, bounded web-area
reader whose entry point is simply not public yet. What it needs is the Chromium wake:
set both `AXManualAccessibility` and `AXEnhancedUserInterface` on the browser's main pid,
ignore both return codes, and poll for the web area for up to six seconds. The measured
behaviour is recorded in the reference port
(`../Bonnie/Sources/BonniePlugin/AXEngine/Web/WebAXWakeup.swift`): Chrome refuses one
attribute outright, half-refuses the other, and wakes about 2.3 seconds later anyway;
Electron is the exact mirror. Gate it on `WebContentHost.classify(pid:bundleID:) != .none`
— that classifier is the blast radius for the relayout side effect.

**Why deferred.** The base case does not need it, and adding it first would have hidden
the question this work existed to answer: whether a page can be driven from pixels alone.
It can. Stage 3 makes the answer *better* on one browser rather than possible on both,
and doing it second means the vision lane had to be good enough to stand on its own —
which is now pinned by five real captures in `VisionAX/Tests/VisionAXTests/Fixtures/media/`.

## Things that were measured, and are easy to get wrong again

- **The pointer must really move.** A `mouseMoved` posted to the process leaves the
  cursor where it was, so a page asking the window server where the pointer is still says
  "not over the video" and keeps the controls hidden. Warping the cursor moves it but
  generates no event, so the page is never told. Only a real move through the HID tap
  does both — and after any posted event the window server suppresses local mouse
  handling for a quarter of a second, which is most of the time a reveal has, so
  `PointerDriver.hover` turns that suppression off explicitly.
- **A click on page content goes through the same tap.** A pid-posted click is invisible
  to a rendered page's hit testing: a correctly aimed press on a play button reported
  success and moved nothing, repeatedly. The pointer is put ON the control first, so the
  press lands where the pointer is visibly sitting. Browser *shell* buttons are still
  pressed through Accessibility, which does work.
- **Controls take about a quarter second to draw.** A capture 60ms after the pointer
  lands shows bare video; 250ms shows the whole bar. The engine waits 400ms and, if it
  still sees nothing, moves again at a different depth and looks again.
- **The capture scale is measured, never assumed.** This layer used to request
  `width * 2` and believe it; on a 1× external display that cropped the wrong half of
  every window.

## What it is worst at

**White glyphs over a bright frame.** A player draws its controls in white on a scrim; on
the brightest frames of a video the scrim is not enough, and the play button is neither
brighter than its surroundings nor separable by an absolute level. The transport is then
not found, the engine moves the pointer and looks again, and if it still cannot see one it
says so. `youtube-safari-bright-frame.png` is that case, and its test pins the invariant
that matters: on a hard frame the lane REFUSES rather than reporting a transport somewhere
else on the page. A refusal costs a retry; a wrong transport costs a click on somebody's
Subscribe button.

**A bar with no accent anywhere.** Progress is found by its colour — the played portion is
painted in the site's accent, which is the one part of a translucent bar that does not
carry the video's own variation. A player showing a completely grey track with nothing
played is refused, because at that point it is indistinguishable from a page divider.
Every player found so far draws an accent nub or a scrubber knob.

**Naming a volume glyph.** A real speaker icon matches the drawn silhouettes about half
the time. The volume control is therefore found by position — every player puts it right
after play — which is good enough to press and not good enough to read, so `isMuted` stays
unknown unless a glyph actually said so, and a mute is verified by the button CHANGING
rather than by what it changed to.

## Watching it

```sh
swift run mary-web-probe --browser safari                     # what Accessibility sees
swift run mary-web-probe --browser safari --perceive          # and what sight sees
swift run mary-web-probe --browser chrome  --media toggle    # drive it, and put it back
swift run mary-web-probe --browser safari --media seek=0.5
swift run mary-web-probe --browser safari --open https://example.com
swift run mary-web-probe --browser safari --perceive --dry-run   # what it WOULD press
swift run mary-web-probe --browser safari --save /tmp/page.png   # the exact pixels it reads
swift run mary-web-probe --browser safari --media toggle --watch # the engine's events
swift run mary-web-probe --browser safari --hover-at 450,300     # does a hover reach the page
swift run mary-web-probe --browser safari --route "the first video" --verb press
swift run mary-web-probe --browser safari --save-roster /tmp/page.json   # the read, recorded
swift run mary-web-probe --fixture /tmp/page.json --route "accept all"   # argued offline
swift run mary-ax-probe --app Safari --tree --role toolbar       # measure a browser's shell
```

`--media` puts playback back the way it found it, the same courtesy `mary-media-probe`
pays a music player. `--save` writes the crop the page lane actually reads and then says
what it made of it, which is how every detector fix in this lane was found.

When the detector needs tuning, the loop is offline and repeatable:

```sh
cd ../VisionAX
VISIONAX_MEDIA_FILE=/tmp/page.png swift test --filter readFile        # what it reads
VISIONAX_MEDIA_TRACE=1 VISIONAX_MEDIA_FILE=/tmp/page.png \
    swift test --filter readFile                                      # which gate refused it
VISIONAX_ROW_DUMP=1 VISIONAX_MEDIA_FILE=/tmp/page.png \
    VISIONAX_ROWS=505,507 swift test --filter dumpRows                # the pixels themselves
```

A capture worth keeping becomes a fixture in `Tests/VisionAXTests/Fixtures/media/` with a
test in `MediaFixtureTests`, so the next change to the detector has to keep it working.

## One thing that changed elsewhere

The moment `browsing.mary` ships, the ambient observer stops publishing an affordance
slate for browsers: it retracts whenever `AmbientPlaceResolver.isBrowser` is true, which
until now was never. Generic "press Reload" on a browser's own toolbar stops coming from
the poll, and `navigate_back`, `navigate_forward`, `reload_page` and `list_tabs` are the
replacement for the shell.

For the PAGE, the slate came back — published by a page read rather than by a poll, which
is the doctrine holding: pixels are read when a skill asks and at no other time. So
`act_on_screen` works on a browser again, and it works by *being* `click_on_page`: the
browser arm of `AffordanceRecipes` delegates to the engine rather than pressing anything
itself. The slate is retracted the moment a verified navigation makes every row in it
wrong.
