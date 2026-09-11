# 10 · Every exit

← [Dispatch](9-dispatch.md) · [Map](README.md) › **Exits** › [Beyond](11-beyond.md) →

Cross-cutting · every way a turn can end

---

A turn ends by finishing its continuation. Most endings are *named*, via
`logTurnExit`, and that name lands in Console under subsystem `nyc.rao.mary`,
category `turns`.

**To watch them live:**

```bash
log stream --predicate 'subsystem == "nyc.rao.mary" AND category == "turns"'
```

## The named exits

Nine call sites, in the order a turn could reach them:

| # | Exit name | Line | Stage | Meaning |
|---|---|---|---|---|
| 1 | `held dictation` | [L116](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L116) | [Entry](1-entry.md) | A dictation session owns this speech; it is text, not a request |
| 2 | `cancelled during observer refresh` | [L169](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L169) | [Entry](1-entry.md) | Superseded while adapters were publishing |
| 3 | `bare stop while routines ran` | [L247](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L247) | [Decide](2-decide.md) | One "stop" halted everything |
| 4 | `reference correction` | [L500](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L500) | [Route](3-route.md) | "no, the other one" re-aimed and answered |
| 5 | `embedding dispatch <name>` | [L508](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L508) blk | [Prepare](4-prepare.md) | One confident skill; **no model asked** |
| 6 | `cancelled during supporting-context pre-read` | [L611](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L611) | [Prepare](4-prepare.md) | Superseded mid pre-read |
| 7 | `provider unavailable for <id>` | [L689](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L689) | [Prepare](4-prepare.md) | Refused before spending a token |
| 8 | `cancelled during locate` | [L700](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L700) | [Prepare](4-prepare.md) | Superseded while finding the target |
| 9 | `pending skill decision` | [L733](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L733) | [Prepare](4-prepare.md) | A deterministic outcome *is* the reply |

Plus the shared tail — [`closeSkillTurn`](9-dispatch.md#closeskillturn) at
[L2729](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2729) — which logs
whatever exit name its caller passed. Exits 3, 4, 5 and 9 all arrive through it.

## The unnamed endings

Not every ending has a label. These finish the stream directly:

| Ending | Where |
|---|---|
| Offered prose accepted → written | [Decide](2-decide.md), [L299](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L299) |
| The Sewn epilogue completes normally | [Sewn turn](5-sewn-turn.md), ~[L1486](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L1486) |
| Lane B **detached** — the turn completes, the lane keeps going | [L1188](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L1188) |
| Engine seat settled | [L2565](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2565) |
| Engine seat ran out of rounds → wrap-up round | [L2598](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2598) |
| A throw — the stream finishes *throwing* | [L2637](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2637) |

## Two shapes worth telling apart

**Cancelled** (exits 2, 6, 8) — the turn was superseded. It calls
`appendCancelledEpilogue` so history records that an exchange was abandoned
rather than answered. A cancelled *action* turn closes its exchange with a
marker.

**Detached** — not an ending for the work, only for the *waiting*. The turn
completes and the person is free; Lane B becomes a registered routine and
reports through the proactive channel when it lands. See
[the join race](5-sewn-turn.md#the-join-race--the-heart-of-it).

## Reading a turn's timing

Every turn logs a clock sheet on the way out, from the `defer` set in
[`runTurn`](1-entry.md#runturn--bind-the-world-then-hand-off). Four named marks
are laid along the way, so a slow turn is attributed to a stage rather than
guessed at:

| Mark | Laid at | Measures |
|---|---|---|
| `roster` | L392, L431, L597 | each roster projection |
| `triage` | L397 | the one semantic read |
| `pre` | L1062 | fetch-first, before the lanes |
| `lane` | L1168 | the join race |

The sentences live in
[MaryBrain+TurnLog.swift](../../Sources/MaryBrain/Brain/MaryBrain+TurnLog.swift).

---

← [9 · Dispatch](9-dispatch.md) · Next: [11 · Where the file stops](11-beyond.md) →
