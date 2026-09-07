# The canvas

Mary's own windows: pages she draws to show something visually when words would not
do. A chart, a note, a diagram — or, in the flagship, a shader painting a feeling.

**A page is a message, not a place.** It is whole and in memory (`CanvasPage.html`),
loaded into a `WKWebView` in a borderless window of Mary's own, never written to disk,
never fetched from anywhere, never crawled, indexed or acted on. That is the whole
difference from the browser engine: the browser is somebody else's window that Mary
reads and presses; the canvas is hers, and nothing in it needs reading back.

## What it is not

- **Not a browser.** No Accessibility, no pixels, no page map. `NoSiteShortcutsTests`
  and `NoScenarioShortcutsTests` scan the browsing lane only; the canvas evaluates no
  script in any page — the page talks, through one message handler, and Mary listens.
- **Not a place to act.** The stage lease is held while anything is showing and
  released the moment nothing is, so a later stage Skill from any package takes the
  canvas down before it acts (`StageArbiter`, owner `"canvas"`). A page can never
  cover something Mary is being asked to press.
- **Not key.** The window never becomes key or main and is ordered front without
  activating Mary; the person's application keeps the keyboard. A click on the page
  closes it — the one escape hatch a full-screen page with no keyboard focus must have,
  and it sits in a transparent view above the web view because a `WKWebView` swallows
  the click.

## The pieces

| Where | What |
|---|---|
| `Abilities/canvas.mary` | The faculty: `systemControl`, names no application, Skills `canvas.present` / `canvas.dismiss`, capabilities `canvas.present` / `canvas.dismiss`. Packages that show things name it in `dependencies` and `defaultSupportingAbilities`, the way every app package names `window-management`. |
| `Sources/MaryPlugin/Adapters/Canvas/CanvasModels.swift` | `CanvasPage`, `CanvasPlacement` (full screen, panel, rect), `CanvasReceipt`, `CanvasRefusal` — a sentence per refusal. |
| `…/CanvasWindowing.swift` | The seam (`CanvasWindowing`) and the live windows (`LiveCanvasWindows` → `CanvasWindowHost`, main actor, WebKit). |
| `…/CanvasService.swift` | The engine: an actor with `present` / `prepare` / `show` / `hide` / `dismiss` / `dismissAll`, `snapshot()`, `events()`, and the stage lease. |
| `…/CanvasPlugin.swift` | The Skills: `present_page(html, title, placement)` and `dismiss_page`. The page is the model's own composition, so it never takes the no-model lane. |
| `Sources/Probes/CanvasProbe/` | `mary-canvas-probe` — a page from a file, live or dry. |

## The receipt

A page says one thing back: `webkit.messageHandlers.canvas.postMessage({ready, log})`.
`prepare` loads the page **hidden** and waits up to `readyBound` (1.5 s) for that word;
the receipt carries `ready`, the page's `log`, and `timedOut` when it said nothing. The
canvas reports; the caller decides. The model's `present_page` shows a silent page
anyway — a card with no script is still a card. The dance refuses one, because a shader
that did not say it drew is a shader that did not compile.

**Measured:** a hidden `WKWebView` gets no animation frames, so a page that reports from
`requestAnimationFrame` never reports at all. The shader page reports from one
synchronous draw after link, then starts its frames when it is seen.

## Dance, the flagship

`Abilities/dance.mary` depends on the canvas and adds only the shader and the beat:

- `start_dance` — one shader composed through Seer (`SeerShaderComposer` in
  `Sources/MaryBrain/Dance/`, injected into `DancePlugin` at the composition root, the
  way `LookingPlugin` takes its describer), admitted (`GLSLFragment.admit`: WebGL1,
  no textures, no `#version`, a `main()` that writes `gl_FragColor`), rehearsed hidden,
  then five windows to a random beat of 0.25–0.9 s for fifteen seconds, and every window
  down. **A different shader in every window**: the dance starts on the first and the
  other four are composed together while it plays, each joining as it arrives (a variant
  that fails takes the first shader with its own seed). **Never the monitor itself**: a
  dance window is a quarter to seven tenths of the screen on each side, a mood a large
  centred window. Two repair rounds if admission refuses, two if the page fails to compile (the
  compiler's log, with its line numbers moved back onto the shader's own lines — and an
  int where a float belongs on the named line, a bare literal or a loop counter, is
  floated by Mary herself before any model round); after that a refusal that says why.
  **No shader, no window.**
- `show_mood` — the same, held still in one large centred window until dismissed. "How are
  you feeling?" is Mary's; "what do you think I feel like?" is the person's, read off the
  pronouns.
- `stop_dance` — everything down.

The beat runs in a task the engine owns, never the binding's: a dispatch waits twenty
seconds at most and cancels its task, and the binding returns the moment the first window
is up.

### Routing, measured

`"how are you"` is a built-in small-talk seed, and a scored converse verdict blocks the
no-model lane. The dance seeds `"how are you feeling"` under `operate`: it sits **0.906**
from the greeting — under the 0.95 ceiling that would drop both — so "How are you
feeling?" reads as an act by 0.094 and "How are you?" stays a greeting by the same
margin. `DanceCalibrationTests` pins that, opt-in:

```sh
MARY_EMBEDDING_CALIBRATION=1 swift test --filter DanceCalibrationTests
```

## Watching it

```sh
swift run mary-canvas-probe --html card.html --panel --seconds 5 --watch
swift run mary-dance-probe --shader plasma.glsl --watch            # fifteen seconds, five windows
swift run mary-dance-probe --seer --watch                          # the real composer: a troupe of five shaders
swift run mary-dance-probe --shader plasma.glsl --mood --seconds 4
swift run mary-dance-probe --shader broken.glsl --mood             # the compiler's log, then a refusal
swift run mary-dance-probe --shader plasma.glsl --dry-run          # the beat, on paper
```

The `canvas` and `dance` categories on `nyc.rao.mary` carry the same lines the probes
print: prepared / shown / hidden / dismissed / stage, and composed / rehearsed / beat /
finished / refused.
