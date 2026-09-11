# 6 · Lane A — the voice

← [Sewn turn](5-sewn-turn.md) · [Map](README.md) › **Lane A** › [Lane B](7-lane-b.md) →

**Lines 1568–1693** · `runSewnLane` and `runRealtimeSewnLane`

---

Lane A **talks and does not act**. It streams a spoken reply from Sewn and
yields tokens as they arrive. It never dispatches a Skill.

Two runners, one job, different transports.

## Classic — SSE

[`runSewnLane`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L1571). A
loop over `sewnChat.stream(messages:instructions:)`, folding events into a
`SewnLaneResult`:

| Event | Effect |
|---|---|
| `.token` | appended to `result.text` **and** yielded to the caller immediately |
| `.scoped` | books the retrieval request against this exchange |
| `.contribution` | first one wins; also booked on the ledger |
| `.autoMemory` | ORs into the result |
| `.phase` / `.audio` / `.ttsFailed` | ignored — realtime-only events the classic client never emits |

Any throw sets `result.failed = true`. It does not rethrow: a failed voice lane
is a turn that speaks from Lane B's prose instead, not a crashed turn.

> The ledger pairs a contribution with the row's last-booked request **itself** —
> the rule lives beside the row, not in a hand-carried lane local.

## Realtime — WebSocket

[`runRealtimeSewnLane`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L1620).
Same fold, plus audio: PCM chunks are yielded straight to the speaker, so Sewn's
voice plays rather than the local one.

Returns a triple — `(result, serverVoiced, fellBackPreStream)` — which encodes
the fallback rules:

1. **`.ttsFailed`** → server audio stopped mid-turn. Hand the rest to the local
   voice by yielding `.speechSource(.local)`. The turn continues.
2. **A throw with nothing forwarded yet** → `fellBackPreStream = true`, and
   [`sewnTurn`](5-sewn-turn.md) reruns the whole lane on classic SSE.
3. **A throw after content was forwarded** → too late to restart; mark failed
   and hand speech back to local.

The discriminator for rules 2 and 3 is `forwardedAny`, and it is classified **on
the event** (`SewnChatEvent.forwardsContent`), never per-arm here.

> **Why `.scoped` must not count as forwarded content.** The client yields
> `.scoped` before it even connects. Counting it would make every pre-stream
> failure look mid-turn, and rule 2 would never fire.

## Calls out to

[`SewnChatProviding`](../../Sources/MaryBrain/Sewn/SewnChatProviding.swift) ·
[`SewnRealtimeClient`](../../Sources/MaryBrain/Sewn/SewnRealtimeClient.swift) ·
`RetrievalTraceLedger` · `SewnContribution`

Both are thin. The wire, the SSE parsing and the reconnect logic live in
`MaryBrain/Sewn/`; this file only folds events into a result.

---

← [5 · Sewn turn](5-sewn-turn.md) · Next: [7 · Lane B](7-lane-b.md) →
