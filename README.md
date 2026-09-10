# Mary

A macOS ambient-intelligence assistant. Mary perceives your screen through the
accessibility tree, carries out declarative **Plugins** by voice, speaks through
Sewn, and remembers through Thread.

Mary is a re-architecture of [Bonnie](../Bonnie) — the same ideas, cut down to
their load-bearing shape. Three commitments define it:

**Every plugin is a plugin.** A Plugin is a declarative package: one `.mary`
file under `Abilities/` describing an application, the skills it offers, and the
recipes that carry them out. There is no "native plugin" concept — no Swift file
anywhere names a target application. The compiled providers that satisfy what a
Plugin declares are **adapters**, they are generic by construction, and the word
"plugin" never names Swift code.

**Accessibility is tier 0.** The ambient context store takes the AX surface —
what is actually on screen right now — as its foundation, with per-application
facts layered on top and selection/attention above that. The walk that produces
it is the floor of `MaryComputerUse`, which owns everything Mary does *to* the
machine as well as everything she reads from it — see `docs/computer-use.md`. A stale fact renders
with its age and loses authority, because held knowledge ages honestly. A stale
surface is *dropped*, because a screen that may no longer exist is a confidently
wrong answer waiting for a question.

**Ambient intelligence is the philosophy.** Mary's job is to already know what
you are looking at, so that "change the second paragraph" needs no explanation.

## Status

Under construction, in stages. Stage 0 (scaffold, doctrine tests, signing) is
in. See `~/.claude/plans/we-have-implemented-all-atomic-sutton.md` for the
staged plan.

Test plans name the destination, not the incident pile:

- `TestPlans/Mary-Doctrine.xctestplan` — standing rules (layering, admission, purity). Always expected green.
- `TestPlans/Mary.xctestplan` — Doctrine plus perceive / speak-listen / teach-act / turn. Daily run.
- Live AX, voice, corpus, and media stay in the `mary-*-probe` tools.

## Building

Requires macOS 26 (the floor is `SpeechAnalyzer`, the only API for long-form
continuous on-device transcription) and sibling checkouts of `../Frigate` and
`../Conduit` alongside this repository once those stages land.

```sh
swift build
swift test
./scripts/dev.sh          # build, stable-sign, run
CONFIG=release ./scripts/dev.sh
./scripts/make-app.sh     # build/Mary.app
./scripts/sand.sh         # the wireframe + ability bench (its own TCC identity)
./scripts/sand.sh --target com.apple.TextEdit   # open straight onto one app
```

**Use `./scripts/dev.sh`, not `swift run`.** SwiftPM signs the built binary
ad-hoc, and an ad-hoc identity *is* the binary's cdhash — it changes on every
build, so macOS treats each rebuild as a brand-new app. The System Settings
checkbox still looks enabled while `AXIsProcessTrusted()` quietly returns false.
`scripts/sign-binary.sh` re-signs with a stable certificate (an Apple
Development identity, or a self-made one named `Mary Dev Signing`) so the
designated requirement is identifier + certificate rather than a hash, and one
Accessibility grant survives every rebuild. The Xcode scheme carries the same
logic inlined in a **launch pre-action** — pure SwiftPM packages have no build
phases, and `SRCROOT` does not resolve in scheme actions, so only
`BUILT_PRODUCTS_DIR` works there.

Kokoro's speech models (~665 MB) are tracked with git-lfs; run
`git lfs install` before cloning or the voice target builds against
placeholder files.

## Layout

One SwiftPM package, targets under `Sources/`, layered strictly:

| Target | What it is |
|---|---|
| `MaryFoundation` | The schema layer: Plugin grammar, codec + integrity digest, value envelopes, `AXFrame` geometry. Depends on nothing. |
| `MaryAmbient` | The ambient paradigm: the tiered context store, realms, surfaces, passages, focus and reference resolution. Depends on `MaryFoundation` **alone** — that is what makes it portable, and a test enforces it. |
| `MaryComputerUse` | The machine layer: the accessibility tree engine (tier 0), derived sight, hands (keyboard, pointer, elements, windows, menus, media keys), stage arbitration, subprocess, and one monitor. The only target that posts an input event, performs an accessibility action, or captures pixels — and a test reads every source file to keep that true. |
| `MaryPlugin` | The adapter contract and the generic adapters (surface, typer, prose-surface, window management, media, corpus). Adapters translate what a Skill needs into hands and sight; they do not reach the machine themselves. |
| `MaryVoice` | Mic → VAD → transcription → a `LanguageResponder` seam → speech, every stage observable. |
| `MaryBrain` | Reasoning: the dual-lane turn, the Plugin pipeline, the Sewn clients. Every generation rides Sewn — Mistral, Thinking Machines, or Sewn's own on-device model — so no model is ever loaded in this process. |
| `MaryThread` | The gRPC facade onto the local Thread node. Consumed only by the runtime and the app. |
| `MaryRuntime` | The composition root, long-lived actors, and Granite services. |
| `Mary` | The SwiftUI app. |
| `Sand` | The bench: a live accessibility wireframe of any running app, and one taught ability — its own recipes, or any skill it realizes for a discipline it extends — dispatched through the real `AbilityRuntime` so the route it takes into `MaryComputerUse` is watchable act by act. Its own bundle id, so its Accessibility grant is independent of Mary's. `./scripts/sand.sh` to run it. |

Those rules are not conventions — `Tests/MaryFoundationTests/PackageLayeringTests.swift`
reads `Package.swift` as text and fails the build when an edge appears that
should not, because SwiftPM offers no build-time hook for "this target may not
depend on that one" and a wrong edge forms no cycle: it compiles, links, ships,
and the boundary is simply gone.
