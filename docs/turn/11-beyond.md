# 11 · Where the file stops

← [Exits](10-exits.md) · [Map](README.md) › **Beyond**

Cross-cutting · the 212 calls out, and what is on the other side

---

The turn file is the **join**, not the substance. It declares 15 functions and 3
types, then calls 212 functions it does not own. Almost every noun and verb in
it belongs to somebody else.

| | Count |
|---|---|
| Distinct call names used | 227 |
| …defined **elsewhere** | **212** (93%) |
| Project types referenced | 106, across **79 files** |
| Modules reached | **6** |

Those six are every layer `MaryBrain` is permitted to see. The file saturates
its own legal reach — and by repo-wide measurement it touches more distinct
defining files (79) than any other file in `Sources/`. The runners-up are
composition roots and CLI entry points; among files that *execute a turn*, this
one has no rival.

## Next door — the rest of `MaryBrain/Brain/`

The turn's closest collaborators. These are the ones to read next:

| File | Holds |
|---|---|
| [MaryBrain.swift](../../Sources/MaryBrain/Brain/MaryBrain.swift) | the actor, its stored state, `maxSkillRounds`, the grace constants |
| [MaryBrain+History.swift](../../Sources/MaryBrain/Brain/MaryBrain+History.swift) | `appendHistory`, `sanitizedSpoken`, `pruneSyntheticTurns`, trimming |
| [MaryBrain+Route.swift](../../Sources/MaryBrain/Brain/MaryBrain+Route.swift) | `locateTarget`, `revisionReport` — the revision spine |
| [TurnTriage.swift](../../Sources/MaryBrain/Brain/TurnTriage.swift) | the semantic read. Abstains, never guesses |
| [MaryBrain+RepeatGuard.swift](../../Sources/MaryBrain/Brain/MaryBrain+RepeatGuard.swift) | why a lane declines to re-run what it just ran |
| [MaryBrain+GroundedText.swift](../../Sources/MaryBrain/Brain/MaryBrain+GroundedText.swift) | `spokenReadBack`, the grounded-results block |
| [MaryBrain+Routines.swift](../../Sources/MaryBrain/Brain/MaryBrain+Routines.swift) | detached lanes, once they stop being turns |
| [MaryBrain+FollowUpSpeech.swift](../../Sources/MaryBrain/Brain/MaryBrain+FollowUpSpeech.swift) | what a routine says when it finally lands |
| [BrainConcurrency.swift](../../Sources/MaryBrain/Brain/BrainConcurrency.swift) | `TurnBox` (epochs, supersede), `LaneEmitter`, `LaneAttachment` |
| [MaryBrain+TurnLog.swift](../../Sources/MaryBrain/Brain/MaryBrain+TurnLog.swift) | every sentence this map quotes from Console |

## Downward — the layers

```
        respond(to:)
             │
   ┌─────────▼──────────┐
   │  MaryBrain+Turn    │  ← you are here (2,739 lines)
   └─────────┬──────────┘
             │ dispatcher.dispatch(…)
   ┌─────────▼──────────┐
   │  AbilityRuntime    │  resolve · guardrails · confirmation parks
   └─────────┬──────────┘
   ┌─────────▼──────────┐
   │  MaryPlugin        │  30,785 — the adapters that know an app
   └─────────┬──────────┘
   ┌─────────▼──────────┐
   │  MaryComputerUse   │  10,601 — the ONLY layer that touches the machine
   └────────────────────┘

   alongside:
     MaryAmbient  17,533   perception, routing, the world
     MaryVoice     8,971   the ear and the mouth
     MaryFoundation        the schema everything is written in
```

**The layering is enforced, not conventional.**
[`PackageLayeringTests`](../../Tests/MaryFoundationTests/PackageLayeringTests.swift)
reads `Package.swift` as *text* and fails the build on violations — including if
`MaryBrain` ever names an MLX product, because generation belongs to Sewn now.

## Outward — Sewn

Every generation leaves the process. The clients are in
[`Sources/MaryBrain/Sewn/`](../../Sources/MaryBrain/Sewn/), one per route:

| Client | Route | Used by |
|---|---|---|
| `SewnChatClient` | `/v1/chat/completions` (SSE) | [Lane A](6-lane-a.md) |
| `SewnRealtimeClient` | `/v1/realtime/chat` (WS) | [Lane A](6-lane-a.md) |
| `SewnSkillClient` | `/v1/skills/complete` | [Lane B](7-lane-b.md), via `MarySewnSkillEngine` |
| `SewnCodeClient` | `/v1/code/complete` | the coding agent |

Each sends a `provider` — `mistral` \| `local` \| `tinker` — which is the user's
engine choice from Settings. **The choice says which backend Sewn uses, never
whether Sewn is used.** `local` means on-device *inside Sewn*, not inside Mary.

## The one thing this file must not become

It is 1.7% of `Sources/` and reads as much more, because control flow is where
meaning concentrates. That only holds while it stays a coordinator.

The moment substance starts landing here — a parser, a scoring rule, a codec —
the join stops being legible, and this map stops being true. The six-file split
this replaced was a symptom of exactly that pressure, handled badly. Keep the
verbs; let the nouns live where they belong.

---

← [10 · Every exit](10-exits.md) · [Back to the map](README.md)
