# Computer use

Everything Mary does *to* this Mac, and everything she reads from it, lives in
one target: `MaryComputerUse`. This page is the map.

## Why it is one target

The acts were spread across four. The accessibility engine and most primitives
sat in `MaryPlugin` beside the adapters that call them; the pointer lane had
grown a second copy of itself inside `MaryBrain`, which synthesized its own
`CGEvent`s and walked its own accessibility trees. Nothing failed, because a
forbidden call compiles, links and ships.

One target makes three things true:

- **"What can Mary do to my Mac" has one place to look.** The answer is the
  `Hands/` directory, plus one pixel read in `Sight/`.
- **Every act passes one monitor.** An act nobody can see is the one that goes
  wrong quietly.
- **The adapters read as what they are.** `MaryPlugin` translates what a Skill
  needs into hands and sight, and cannot reach past them.

## The lanes

```
MaryFoundation → MaryAmbient → MaryComputerUse → MaryPlugin → MaryBrain → …
```

| Lane | What lives there |
|---|---|
| `Accessibility/` | **Tier 0.** One bounded walk of a process's accessibility tree into plain Sendable values: `AXTreeWalker` → `AXSnapshotBuilder` → `AXAppSnapshot` → `AXElementRoster` → `AXAmbientContext`. Read-only, one-shot, no streamer — Mary polls. |
| `Sight/` | Derived reads over that tree — page elements, the declared text surface, the last-acted element — plus `WindowPixels` (the one capture path, with a MEASURED scale) and `ScreenRegionCapture`, the ephemeral look. |
| `Sight/Vision/` | What a page looks like, through VisionAX: `VisionPageReader` (the only importer of that module), `MediaControlReading`, `PageMapSummary` — which rows a page offers, what each affords, and where its name came from — and `PagePerceptionPipeline`, where a second perception lane will join. See [browser-engine.md](browser-engine.md). |
| `Hands/` | The acts, by instrument: `Keyboard/` (chords, typing), `Pointer/` (move, click, drag, scroll, anchor capture, and the two acts that reach the whole machine — `hover` and `clickThroughHID`, each carrying the measurement that earned it), `Elements/` (press, set, focus), `Windows/` (raise, full screen, restore), `Menus/`, `MediaKeys/`. |
| `Stage/` | Who holds the machine and proof that they do: verified activation, arbitration between observers, bounded waits, single-poller claims. |
| `Process/` | `Subprocess`. Mary-owned tools only, never a shell. |
| `Monitor/` | `ComputerUseMonitor` — the snapshot and event stream every lane reports into. |

`MaryAmbient` keeps its own selection reader, which talks to `AXUIElement`
directly. That is deliberate: the ambient paradigm must stay portable on
`MaryFoundation` alone, and `PackageLayeringTests.ambientDependsOnFoundationAlone`
forbids the edge that would let it borrow this layer instead.

## The two rules

**Accessibility/ imports nothing from Sight/, Hands/, Stage/ or Process/.** The
tree read is the floor; a walk that consulted the hands could not be reasoned
about or tested without them. The one exception is the monitor, which a walk
reports its cost to. When a dependency runs the wrong way, invert it — the
window-list read moved down into `AXWindowRoster` and `AccessibilityWindowCore`
now forwards to it, rather than tier 0 calling up into `Hands/Windows/`.

The vision engine is a dependency of this target and of no other, and only
`Sight/Vision/` imports it. That is not tidiness: VisionAX replicates this layer's AX
vocabulary by name — `AXNodeSnapshot`, `AXScreenElement`, `AXNodeCategory` — deliberately,
so its trees are shaped like ours, and a second importer would make every use of those
names ambiguous at the use site rather than at the import.
`Tests/MaryComputerUseTests/VisionAXSealTests.swift` holds the line inside the module;
`PackageLayeringTests` holds it in the manifest.

It arrives **through Frigate**, as the `FrigateVisionAX` product — Frigate hosts the ML
surfaces this repository takes, and pixel perception is one of them. The vision product
carries the perception engine and, since the classifier's backbone moved to Metal
(2026-09), MLX's core with it — none of Frigate's transformer names — and
`frigateInferenceOnlyThroughBrain` polices the split per product. The seal watches **every
spelling**: `import FrigateVisionAX` and `import VisionAXCore` both carry the colliding
names, because a re-export carries everything and SwiftPM puts every module in the graph
on the search path whether or not a target declared the edge; `import FrigateVision` and
`import VisionAX`, the module's former names, stay forbidden too.

**No target above MaryComputerUse posts an input event, performs an
accessibility action, or captures pixels.** Reads are fine: asking
`AXUIElementCopyAttributeValue` or `AXIsProcessTrusted` changes nothing.

Both rules are read out of the sources by
`Tests/MaryComputerUseTests/OnlyComputerUseTouchesTheMachineTests.swift`, which
carries a named allowlist — each entry with the reason it is tolerated and a
token that must still be present, so a repurposed file falls out of the
allowlist rather than inheriting it. Two entries are flagged rather than
blessed: `MediaSurfaceLibrary` and `ProseSurfaceAX` still act directly and
should route through `Hands/`.

`Tests/MaryBrainTests/PluginRuntimePurityTests.swift` pins the same boundary
from the other side: the brain's hands may name `KeyChordPress`,
`KeyboardTyper`, `PointerDriver` and `AccessibilityAnchorLocator`, and may not
name `CGEvent` or `AXUIElement` at all.

## The monitor

`ComputerUseMonitor.shared` is a lock-guarded value, not an actor, and that is
a design choice about ordering: every report site is a synchronous static
function, so hopping onto an actor would cost a task allocation per keystroke
chunk and could deliver an act after the refusal that followed it. Reporting
must never fail, block, or reorder the act it describes.

It offers `snapshot()` (per-lane tallies, the last refusal, the accessibility
and screen-recording grants, a walk-cost tally, a bounded tail) and `events()`
(an `AsyncStream` that replays current state to a new subscriber first, so a
watcher attaching late still sees where things landed). Sequence numbers are
monotonic across acts and refusals, so a gap means dropped events rather than
quiet.

**Every refusal is named.** `ComputerUseRefusalReason` exists so a skipped act
says why it skipped: `accessibilityUntrusted`, `noCapturedSpace("row")`,
`anchorNotUnique`, `itemDisabled("Move To")`. A bare `false` travelling up the
stack is the failure mode this type replaced.

Content never enters. The typing lane reports a character count, never the
characters; the capture lane reports a size in bytes, never the pixels; the
process lane reports a tool name and an argument count, never the arguments.

## Watching it

```sh
swift run mary-ax-probe --watch          # tail the running app's acts
swift run mary-ax-probe --watch --self   # subscribe in-process, see the stream API
swift run mary-ax-probe --app TextEdit   # a live walk, then the monitor snapshot
./scripts/sand.sh                        # the bench: run an ability, watch the lanes
```

`Sand` (`Sources/SandApp`) is the visual counterpart of `--watch --self`. It
hosts its own `AbilityRuntime` in-process, so dispatching one taught Skill puts
that Skill's acts and refusals on a timeline beside a live wireframe of the app
they landed in — and because the runtime is real, the route is the route.
Its "Observe" toggle tails the log mirror as well, which is how it watches a
separately running Mary.

```sh
./scripts/sand.sh --target com.apple.iCal
./scripts/sand.sh --target com.apple.iCal --run calendar_go_today
```

`--target` opens straight onto one application; `--run` also dispatches one
ability, so a run is repeatable from a script. `--run` performs the ability for
real — it is opt-in for that reason, and never implied by `--target`.

The bench lists an expertise in lanes, because an expertise usually owns
nothing: Apple Music carries one recipe and *realizes* the nine skills the
`multimedia` discipline declares, which the compiled `media-surface` adapter
carries out. Each row says who its hands are — `hands here · <operation>` for a
recipe this package realizes, the adapter's name otherwise — so a run that
produces no acts can be read against what was supposed to act. The derivation is
`AbilitySkillBench` in MaryBrain, the same one Ability Studio's Skills pane
lays out.

```sh
./scripts/sand.sh --target com.apple.Music --run control_playback --arg action=pause
./scripts/sand.sh --target com.apple.Music --say "play a playlist"
```

The bench has two lanes. **Direct** calls a skill by name, which bypasses
routing and the offer ledger — useful for exercising hands, honest about what it
skips. **Turn** runs Mary's real turn: Sand hosts a `MaryBrain` whose inference
engine is a seat for a person, so the utterance is published, its vector warmed,
the route resolved and the roster projected exactly as in the app, and the model
round hands you the same skill list the model would receive. What a turn offers
is what the words earned: "what is playing right now" offers one skill, "play a
playlist" offers five, and the roster pane names the disposition and reason for
every skill it did not offer. A turn that acts without ever asking for a round
took the confidence lane, and says so.

### A browser on the bench

A browser is the one target whose Accessibility tree does not describe what is
on the screen: the tabs, the address field and the toolbar are all it has, and
everything a page offers is drawn inside a hole. Sand shows both readings at
once — the AX wireframe underneath, and the page as VisionAX read it on top.

```sh
./scripts/sand.sh --target com.google.Chrome --read-page
./scripts/sand.sh --target com.apple.Safari --read-page \
    --say "open the first result" --auto
```

**Read page** dispatches `read_page` through the runtime, exactly as a turn
would; `--read-page` is the same press from a script. Nothing perceives on its
own — pixels are read when a skill asks — so the overlay is empty until a read
happens and says how old the one it is drawing is. Rows are coloured by what
they afford (green presses, blue fills, orange adjusts, grey nothing) and a row
whose name the reading had to invent is dashed and reads `(unnamed)`: nothing
can be asked for by a name the page never wrote. The ambient inspector says the
same thing in text — the AX rows are labelled **Shell**, and **Page offers**
lists what a phrase could actually reach, "3 of 27 rows" being the whole
diagnosis when a read goes badly.

The timeline carries the browsing engine's own stream beside the machine
layer's: `resolved Chrome`, `read the shell`, `looked — 27 rows, 21 named`,
`matched "the first one" → "Alpine touring boots"`, then the click the hands
report, then `receipt` and `verified`. A browsing turn is mostly decisions, and
none of them are acts — a timeline with only pointer events shows a click in the
middle of nowhere. Result rows print the receipt words behind the summary:
`landed`, `found nothing`, the application that answered, and the adapter trail.

```sh
swift scripts/window-id.swift "" Sand    # Sand owns its own windows, not Mary's
screencapture -o -l<window id> /tmp/sand.png
```

**The monitor is process-local.** `ComputerUseMonitor.shared` remembers what
*its own* process did, so a probe cannot subscribe to the running app's
instance. Every report site also writes one public line to
`os_log(subsystem: "nyc.rao.mary", category: "computer-use")`, and `--watch`
tails that. Nothing appears if the app was built without `./scripts/dev.sh`:
an ad-hoc identity loses the accessibility grant, so the hands refuse before
they ever act — and a silent monitor looks the same as a quiet one.
