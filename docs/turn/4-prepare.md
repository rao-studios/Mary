# 4 · Prepare — and the fork

← [Route](3-route.md) · [Map](README.md) › **Prepare** › [Sewn turn](5-sewn-turn.md) / [Engine seat](8-engine-seat.md) →

**Lines 505–753** · the last chance to answer without a model, then the split

---

## The one no-model dispatch

[L508](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L508). If triage found
exactly one confident skill and the sentence is simple enough to claim, the turn
dispatches it and closes. No model is asked anything.

All of these must hold:

- no pending confirmation, no edit intent, no deterministic decision already made
- `route.intent == .operate`
- triage returned a **unique** skill
- `EmbeddingRouting.confidenceShape(of:utterance:)` gives a shape
- and either the skill extracts its own span, **or** the utterance is a single clause

> **Why the clause rule.** A verb carrying no span claims the *whole* sentence,
> so it may only act on a whole simple one. A skill that extracts a span already
> reads around the joiners it finds.

It closes via [`closeSkillTurn`](9-dispatch.md) with exit
`embedding dispatch <name>`. Window verbs arrive here too now — they are
ordinary Skills that happen to need no argument, and the hand-written gate that
used to name them is gone.

*This is the path you see in Sand as `lane: confidence — no model round`.*

## Building what the model will see

- **[L596](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L596) — roster, projected again.**
  The referent moves the roster, reaching arbitration through window-management
  target classes. The trace record must project *again* rather than reuse the
  routed one.
- **[L606](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L606) — supporting context.**
  If the route named a phrase worth pre-reading, it is read now → can **exit
  `cancelled during supporting-context pre-read`**.
- **[L619](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L619) — the system prompt.**
  Base prompt plus, conditionally, the supporting passage, a selection-revision
  instruction, or a deictic attention brief.
- **[L644](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L644) — the trace opens.**
  `AmbientTraceLog` gets the route row; the retrieval ledger opens *beside* it
  joined by the same exchange id, before either lane exists.

## Preflight — refusing early

[L665](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L665). If the turn is
an action, or the utterance named an application, each candidate provider is
checked before any model spends a token. An unavailable one says so and stops →
**exit `provider unavailable for <id>`**.

## Locate

[L695](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L695). When the route
says the turn needs a target, `locateTarget` finds the passage being talked
about. Cancellation here → **exit `cancelled during locate`**.

## THE FORK

[L712](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L712):

```swift
guard sewnReady, let sewnChat else {
    await engineTurn(…)      // no Lane A — one loop acts and speaks
    return
}
```

| Condition | Goes to |
|---|---|
| A `SewnChatProviding` exists **and** is ready | [5 · Sewn turn](5-sewn-turn.md) — two lanes |
| Otherwise | [8 · The engine seat](8-engine-seat.md) — one loop |

This is **not** an on-device / hosted choice. Generation lives in Sewn either
way; the engine picker only tells Sewn which backend to use. The fork asks one
question: *does this brain have a voice lane at all?* Sand's bench is the
production case where it does not.

One last shortcut before Lane A spawns —
[L728](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L728): if a
deterministic decision already ran, its summary *is* the grounded reply. Zero
latency, no model in the loop to re-ask or embellish → **exit
`pending skill decision`**.

## Exits from this stage

| Exit | Line |
|---|---|
| `embedding dispatch <name>` | [L508](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L508) block |
| `cancelled during supporting-context pre-read` | [L611](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L611) |
| `provider unavailable for <id>` | [L689](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L689) |
| `cancelled during locate` | [L700](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L700) |
| `pending skill decision` | [L733](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L733) |

## Calls out to

`EmbeddingRouting` · `AmbientTraceLog` · `RetrievalTraceLedger` ·
`locateTarget` ([MaryBrain+Route.swift](../../Sources/MaryBrain/Brain/MaryBrain+Route.swift)) ·
`systemPromptProvider` · `MaryPrompts` · `SewnChatProviding.isReady`

---

← [3 · Route](3-route.md) · Next: [5 · Sewn turn](5-sewn-turn.md) →
