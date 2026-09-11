# 1 · Entry

[Map](README.md) › **Entry** › [Decide](2-decide.md) →

**Lines 33–202** · `runTurn` and the prologue of `runTurnBody`

---

A turn begins outside this file. `VoicePipeline` or `TextTurnRunner` calls
`respond(to:)`, which reserves an epoch and spawns
[`runTurn`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L33) —
see [MaryBrain+LanguageResponder.swift:31](../../Sources/MaryBrain/Brain/MaryBrain+LanguageResponder.swift#L31).

## `runTurn` — bind the world, then hand off

[L33](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L33). It does almost no
work of its own. Its job is to freeze what this turn is allowed to see, so that
nothing below can be answered twice with two different truths.

1. **Start the clock.** `turnClockStart`, `turnMarks`, and a `defer` that logs
   the whole timing sheet on the way out.
2. **Capture the selection** before anything else can steal focus. A request
   owns the selection that existed *before* Mary's UI became frontmost.
3. **Freeze the registry.** `dispatcher?.abilitySnapshot` — Ability Studio can
   activate a new registry mid-turn; this turn keeps the one it started with.
4. **Ask the classifier once.** `isDeictic` is computed here and *carried down*,
   never re-asked.
5. **Bind four task-locals**, then call `runTurnBody` inside all of them:

   | Task-local | Carries |
   |---|---|
   | `AbilityTurnContext` | the frozen registry |
   | `SchemaSignalTurnContext` | what the adapters perceive |
   | `AmbientSelectionTurnContext` | the selection handoff |
   | `AmbientRouteTurnContext` | a write-once box the route lands in |

   Nested rather than flattened because each is a `@TaskLocal`: everything the
   body awaits inherits all four.

> **Why this matters.** An empty snapshot means "nothing selected this turn."
> A *nil* task-local means "not inside a turn at all." Code below can tell
> those apart only because binding happens here, once.

## `runTurnBody` prologue — supersede, then open the exchange

[L81](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L81).

- **[L92](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L92) — supersede.**
  An amended utterance cancels the in-flight turn and removes its exchange from
  history. Otherwise, if this epoch is still current, a stale open exchange is
  closed.
- **[L105](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L105) — the one deterministic consult.**
  `DeterministicTier.decision(in:)` reads a bare yes / no / stop. Everything
  else this turn asks about the words, it asks semantically.
- **[L112](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L112) — held dictation.**
  A dictation session owns unaddressed speech. If one is open, the utterance is
  text, not a request → **exit `held dictation`**.
- **[L130](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L130) — named discipline.**
  "fix the build…", "add a scene…" — asked of the installed disciplines
  semantically, classified once, seeded into the engine later.
- **[L158](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L158) — prepare the turn's context.**
  Adapters publish what they perceive; the utterance is vectorized and routing
  memory recalled. With no vectorizer and no memory backend this is skipped
  outright — nothing to do is not work.
- **[L184](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L184) — the turn gets an identity.**
  `BrainTurn(role: .user, …)`. Its `id` is also the episode id, and it leads
  every path from here.
- **[L202](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L202) — the exchange opens.**
  Guarded: only a turn that is still *current* may claim it, and only a turn
  that exits while still current closes it.

## Exits from this stage

| Exit | Line |
|---|---|
| `held dictation` | [L116](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L116) |
| `cancelled during observer refresh` | [L169](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L169) |

## Calls out to

`SelectionHandoffCoordinator` · `AbilityLibrary` · `AmbientRanker.isDeictic` ·
`EditIntentClassifier` · `DeterministicTier` · `MaryEmbeddings` ·
`RoutingHabitMemoryProvider` · `TurnBox` ([BrainConcurrency.swift:125](../../Sources/MaryBrain/Brain/BrainConcurrency.swift#L125))

---

← [Map](README.md) · Next: [2 · Decide](2-decide.md) →
