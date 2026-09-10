# 9 · Dispatch

← [Engine seat](8-engine-seat.md) · [Map](README.md) › **Dispatch** › [Exits](10-exits.md) →

**Lines 2654–2738** · the ceremony every deterministic dispatch shares

---

Small, and the most-reused code in the file. Four paths wrote this out longhand
before it existed; the only thing that ever differed was one flag.

## `performSkillTurn`

[L2660](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2660). Six steps,
always in this order:

1. Build a `ModelSkillInvocation` with a prefixed run id.
2. Yield `.skillInvocation` — this is what draws the chip in the UI.
3. Dispatch, wrapped in the routing-habit grant.
4. Yield `.skillResult` carrying a `BehavioralActionRecord`.
5. Append the **invocation and result as a pair** to history.
6. Return the `SkillOutcome`.

Step 5 is why this exists. The pair must be appended together or a `tool_use`
can end up in history with no `tool_result` beside it.

### The two optional flags

**`allowTitleCommit`** — armed only for a shortcut dispatch. A title match with
no exact candidate may commit to its best guess rather than refuse. Lane B and
model-driven dispatches never set it.

**`routingHabitGrant`** — what this dispatch may teach the router, or nil to
teach nothing. Only paths that genuinely *are* a routing decision pass one:

| Passes a grant | Does not |
|---|---|
| The deciding gates (confirm / cancel) | The window verbs' old hand-written gate |
| The accepted-prose road | — |

> "yes please" is not a way of asking for anything, so it must not teach the
> router that it is.

**One lesson per lane.** The grant is built once from the words that started the
turn, so a multi-round turn cannot teach the router three different things, and
the query is *this* turn's utterance rather than whatever the process-wide
routing query says by the time a round lands.

## `closeSkillTurn`

[L2718](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2718). The tail the
early-returning paths share: speak if there is something to say, append it,
yield `.completed`, log the named exit, finish the stream.

An **empty** `spoken` still completes. The act was the answer.

> Speaking and closing stay with the *caller* on the model paths — the decision
> path speaks much later, from the Sewn epilogue, and must not close its own
> turn.

## `argumentsJSON`

[L2735](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L2735). JSON for a
flat string map with `.sortedKeys` — the stable key order every dispatch path
already used. Stable ordering is not cosmetic: the
[repeat guard](7-lane-b.md#guards-on-the-dispatch-loop) compares argument
strings, and key order must not read as a different call.

## Where a dispatch actually goes

`dispatcher.dispatch(name:argumentsJSON:runID:)` is a protocol call —
[AbilityDispatching.swift:42](../../Sources/MaryBrain/Brain/AbilityDispatching.swift#L42).
Behind it:

```
AbilityRuntime+Dispatch.swift   →  MaryPlugin adapters  →  MaryComputerUse
   (resolve · guardrails)            (30,785 lines)         (the actual AX act)
```

Nothing above `MaryComputerUse` posts an input event or performs an AX action.
That is a package-level rule, enforced by `PackageLayeringTests`.

---

← [8 · The engine seat](8-engine-seat.md) · Next: [10 · Every exit](10-exits.md) →
