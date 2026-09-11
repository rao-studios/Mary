# 8 · The engine seat

← [Lane B](7-lane-b.md) · [Map](README.md) › **Engine seat** › [Dispatch](9-dispatch.md) →

**Lines 2104–2652** · `engineTurn` — the turn with no Lane A

---

Reached from [the fork](4-prepare.md#the-fork) when this brain has no
`SewnChatProviding`. One loop does both jobs: it acts *and* it speaks.

> **Read the name carefully.** This is **not** an on-device path. Since
> generation moved into Sewn, Mary loads no model in process at all —
> `PackageLayeringTests` fails the build if `MaryBrain` names an MLX product.
> `engine` is whatever `setEngine` installed. What this path means is: *there is
> no voice lane running beside me.*

## Who actually runs it

**Sand.** [`SandTurnHost.swift:132`](../../Sources/SandApp/Turn/SandTurnHost.swift#L132)
builds `MaryBrain(engine:dispatcher:wiring:)` and never calls `setSewnChat`, so
`sewnChat` is nil and every Sand turn lands here. Sand's engine is
[`SandBenchEngine`](../../Sources/SandApp/Turn/SandBenchEngine.swift) — a person
in the model seat, answering each round by hand.

That makes this function the bench's whole turn. Changing it changes what the
bench is evidence *of*.

## The same loop, one difference

Structurally it mirrors [Lane B](7-lane-b.md): rounds, dispatch, repeat guard,
the two rungs, the same early exits.

| | Lane B | Engine seat |
|---|---|---|
| History | private `laneHistory`, merged at join | **shared history, directly** |
| Speaks? | no — prose is fallback only | **yes — it is the only voice** |
| Nudges | discarded with the lane | must be **pruned** afterwards |
| Prose timing | buffered | non-action turns stream **live** |

## Why the nudges need pruning

Because it appends synthetic `.user` turns to the *shared* history, anything it
adds must be named in
[`pruneSyntheticTurns`](../../Sources/MaryBrain/Brain/MaryBrain+History.swift#L178)
or it persists into the next turn as words the person never said.

The three it owns are declared at the bottom of this section:

| Nudge | Line | Says |
|---|---|---|
| [`confirmRelayNudge`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2642) | 2642 | A protected action is waiting — ask them the question, invent nothing |
| [`budgetNudge`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2646) | 2646 | Stop. Say what you accomplished and what remains |
| [`groundedRetryNudge`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2651) | 2651 | A Skill result is above you — read it, no small talk |

`pruneSyntheticTurns` is called at **nine** points in this function — every exit
path, because missing one leaks.

## The round loop

[L2166](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2166), `while round < maxSkillRounds`:

| Step | Line |
|---|---|
| Empty round → one silent retry | [L2247](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2247) |
| No invocations → the rungs, then speak | [L2261](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2261) |
| Dispatch each call, guarded | [L2416](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2416) |
| A Skill asked the person → end, that is the reply | [L2527](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2527) |
| A verbatim repeat of a failed call → end | [L2539](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2539) |
| A CONFIRM parked → relay the question | [L2542](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2542) |

> **A non-action turn streams its prose live** as tokens arrive, which is why
> the continuation rung here is gated on `actionTurn` *alone* — narrower than
> Lane B's wider "implies action" reading. Continuing after it already spoke
> would say the same thing twice. Lane B never runs that risk because it
> buffers.

## The two endings

**Ran out of rounds** ([L2598](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2598))
— the `while` fell through. Append the `budgetNudge` and take one wrap-up round:
*tell them what you did and what is left.*

**Settled** ([L2565](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2565)–[L2596](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2596))
— the model stopped calling things. On an action turn it speaks, in order: an
open question, an unrecovered failure, a revision report, or "nothing ran".

Either way the last act is a `revisionReport`
([L2621](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2621)) — a revision
that burned the whole budget still changed the document, and the wrap-up is
model prose about what it accomplished.

## Tested by

[`EngineTurnRungTests`](../../Tests/MaryBrainTests/EngineTurnRungTests.swift) —
the two rungs and the nudge pruning ·
[`RepeatDispatchTests`](../../Tests/MaryBrainTests/RepeatDispatchTests.swift) —
the repeat guard, on both lanes.

Both call the lane **directly, with a route**: in a unit test there is no
semantic index, so triage abstains and no turn would ever be an action. Driving
`respond(to:)` there would test the router instead.

---

← [7 · Lane B](7-lane-b.md) · Next: [9 · Dispatch](9-dispatch.md) →
