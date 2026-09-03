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
| `Sight/` | Derived reads over that tree — page elements, the declared text surface, the last-acted element — plus `ScreenRegionCapture`, the one pixel read. |
| `Hands/` | The acts, by instrument: `Keyboard/` (chords, typing), `Pointer/` (move, click, drag, scroll, anchor capture), `Elements/` (press, set, focus), `Windows/` (raise, full screen, restore), `Menus/`, `MediaKeys/`. |
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
```

**The monitor is process-local.** `ComputerUseMonitor.shared` remembers what
*its own* process did, so a probe cannot subscribe to the running app's
instance. Every report site also writes one public line to
`os_log(subsystem: "nyc.rao.mary", category: "computer-use")`, and `--watch`
tails that. Nothing appears if the app was built without `./scripts/dev.sh`:
an ad-hoc identity loses the accessibility grant, so the hands refuse before
they ever act — and a silent monitor looks the same as a quiet one.
