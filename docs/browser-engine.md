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

**Stage 4 — pressing page elements by name.** Not started. It needs stage 3 for labels,
or an OCR-labelled roster from the vision lane.

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

The moment `browsing.mary` ships, the affordance slate goes dark for browsers:
`AmbientSurfaceObserver` retracts it whenever `AmbientPlaceResolver.isBrowser` is true,
which until now was never. Generic "press Reload" on a browser's own toolbar stops
working, and `navigate_back`, `navigate_forward`, `reload_page` and `list_tabs` are the
replacement. That is a deliberate trade: the browsing skills know which control they are
pressing and prove the page moved, and the affordance slate did neither.
