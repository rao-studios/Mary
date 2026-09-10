# 3 · Route

← [Decide](2-decide.md) · [Map](README.md) › **Route** › [Prepare](4-prepare.md) →

**Lines 336–504** · the one semantic read, and the route it produces

---

Everything before this was cheap and literal. This is where the turn finds out
what the words *mean* — once, and only once.

## The query, composed

[L365](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L365) —
`RoutingQuery.compose(…)` gathers the utterance plus the world snapshot and
recent user turns.

> **PIN, measured.** Triage scores `RoutingQuery.firstLine` **only**. The
> composed world and history lines measurably dilute a sentence embedding — a
> query that wins bare drops below the floor once composed. See
> [TurnTriage.swift](../../Sources/MaryBrain/Brain/TurnTriage.swift) and its
> calibration suite.

## The pre-route roster

[L391](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L391) —
`dispatcher?.projectRoster().names`. Triage needs the offered names to score
against, so the roster is projected *before* the route exists. It gets projected
again later, after the referent moves it — see [Prepare](4-prepare.md).

## The one semantic read

[L393](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L393) —
`TurnTriage.verdict(…)` returns intent, requested abilities, skill affinities,
and a unique pick if there is one.

> **It abstains, never guesses.** With no vectorizer every field comes back
> empty and the turn falls through to the model. Nothing here falls back to a
> word list — that is the entire point of the file.

At [L400](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L400),
`actionTurn` is settled: an edit intent **or** an action-shaped verdict.
Revision is structure, so it ORs in rather than being embedded in the score.

## The route resolves

[L406](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L406) —
`AmbientEngine.resolve(AmbientEngine.Inputs(…))`. The turn's shape is now known,
so the route can be built and written into the `AmbientRouteTurnState` box bound
back in [Entry](1-entry.md).

Two statics in this file feed those inputs:

- [`addressCandidates`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L755)
  — candidacy follows *publication*, not focus, deliberately the opposite of the
  list used for cue classification.
- [`routableApplicationID`](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L772)
  — resolves an application name to a profile. `requireEvidence` separates the
  two questions this used to answer with one number: a *candidate* may fall back
  to the first serving profile, a *lead* may not.

## One-word correction

[L491](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L491) —
`ReferenceCorrectionGrammar.isCorrection(…)`. "no, the *other* one" re-aims the
referent and answers from the rival → **exit `reference correction`**.

## Exits from this stage

| Exit | Line |
|---|---|
| `reference correction` | [L500](../../Sources/MaryBrain/Brain/MaryBrain+Turn.swift#L500) |

## Calls out to

[`TurnTriage`](../../Sources/MaryBrain/Brain/TurnTriage.swift) ·
`RoutingQuery` · `AmbientEngine` · `AmbientRanker` ·
`ReferenceCorrectionGrammar` · `WorkspaceFocusTracker` ·
`AmbientPlaceResolver` · `AmbientElementIndexStore`

---

← [2 · Decide](2-decide.md) · Next: [4 · Prepare](4-prepare.md) →
