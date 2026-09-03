# Habit vocabulary — follow-ups after the Exemplar rename

The rename is done. "Exemplar" is retired; the routing vocabulary is now two
words, each meaning exactly one thing:

- **seed** — authored, frozen until a human edits it. `intentSeeds`,
  `seedFamilies`, `SemanticSeedFamilyIndex`, `builtInConverseSeeds`.
- **habit** — learned from use, decays. `RoutingHabit`, `ApplicationHabit`.

`SemanticIntentIndex` takes one of each: seeds as its corpus, habits on top.
That is why they could not share a word.

What follows is deliberately **not** done yet. Each item is a separate decision.

## 1. Verb pair: `record` → `train`, and a matching `forget`

The noun moved; the verbs did not. Today both ledgers say `record(_:)`, and only
`ApplicationHabitLedger` has `forget(discipline:)`.

If habits are trained and untrained, the verbs should say so:

| Now | Then |
|---|---|
| `RoutingHabitStore.record(_:)` | `train(_:)` |
| `ApplicationHabitLedger.record(_:now:)` | `train(_:now:)` |
| `EmbeddingRouting.recordRoutingHabits(...)` | `trainRoutingHabits(...)` |
| `RoutingHabitRecordingContext` | `RoutingHabitTrainingContext` |
| *(absent)* | `RoutingHabitStore.forget(skillID:)` |

Untraining then has three honest forms: gradual (decay), bounded (cap/horizon
eviction), and deliberate (`forget`). Only the third is a user gesture.

**Cost:** every call site of `record`, plus the recording-context type name.
**Why deferred:** it is a verb refactor on top of a noun refactor; landing them
together would make the diff unreviewable.

## 2. The two habits do not decay the same way

This is the real finding the rename surfaced, and the reason to keep it visible.

| | `RoutingHabit` | `ApplicationHabit` |
|---|---|---|
| Retention | flat 30-day horizon | continuous half-life |
| Weighting | none — presence only | `StyleRecency.weight(at:now:)` |
| Eviction | per-skill cap 24, total 200 | `decayFloor`, per-discipline cap 120 |
| Effect of age | binary: counts, then gone | tapers to nothing |

Calling both "Habit" invites a reader to assume one mechanism. There are two.

Options:
- **Unify on `StyleRecency`.** One decay curve everywhere the word appears.
  Changes routing behaviour: a 29-day-old row currently counts at full strength
  and would start counting at roughly a half. Needs recalibration against
  `EmbeddingCalibrationTests`.
- **Document the split.** Keep the horizon for routing (a phrasing is right or
  it is not — arguably a cliff, not a slope) and say so in the PIN, so the
  difference reads as intended rather than accidental.

Recommend deciding this before adding a third habit of any kind.

## 3. Wire-format prefixes are now asymmetric

Swift symbols are symmetric; the stored addresses are not.

| Artifact | Group prefix | Document prefix |
|---|---|---|
| Routing habit | `mary-routing-<owner>` | `mary-routing-<intent>\|<skill>\|<epoch>` |
| Application habit | `mary-habit-<owner>` | `mary-habit-ledger-<hash>` |

One says what it routes, the other says what it is. Ideally
`mary-routing-habit-*` and `mary-application-habit-*`.

**Not done because it is a migration, not a rename.** `mary-routing-*`
documents already exist in real Totems from prior sessions; changing the prefix
orphans them (`TotemAddressClassifier` would file them as `.unknown` and the
Totems pane would show them as Unrecognized). Doing it properly means a
read-both/write-new period or a one-off re-address pass.

`ApplicationHabit` has a second wrinkle the routing side does not: its rows are
JSON-encoded into the document body, so its **field names are wire format**.
Renaming `observedAt` or `expertiseID` later needs a decode migration.
`RoutingHabit` never serializes its fields — the id and bare text carry
everything — so it stays free to change.

## 4. Smaller items

- `RoutingHabitStore` is a turn-scoped recall cache; `ApplicationHabitLedger` is
  continuously live. The suffixes (`Store` vs `Ledger`) currently carry that
  difference implicitly. Worth a sentence in each PIN, or unified suffixes once
  item 2 is settled.
- `SemanticAbilityRequestIndex` is the one tier that never consumes habits —
  only `classify` and `affinities` do. That asymmetry is deliberate but
  undocumented; it belongs in the ability index's own PIN.
- Reload-time embedding dedup: `intentSeeds` sentences are vectorized twice
  per reload, once into the ability corpus and once as intent seeds. A
  reload-scoped string→vector cache would fix it. Background cost only, off the
  turn path.

## 5. Retiring the `intentExemplars` decode shim

`AbilityTriggerSchema.CodingKeys` still carries `intentExemplars` so a package
sealed before the rename keeps loading. All 14 shipped packages are migrated and
resealed, and encoding only ever writes `intentSeeds`, so resealing any straggler
migrates it. The shim exists for packages outside this checkout.

Drop it once no such package can plausibly remain — but **not** before, and not
casually: the schema decodes tolerantly and does not reject unknown keys, so
removing the case turns a stale package into an empty intent corpus with no
error at all. `RoutingSchemaSeedTests` pins both spellings and the write-new-only
rule; delete those tests in the same commit or they will look like the failure.

## 6. Unrelated: a test that only passes in company

`GuardrailCategoryProjectionSecurityTests
.theMigratedXcodeBuildOperationRendersItsFixedCautionSentenceThroughRealDispatch`
fails under `swift test --filter` and passes in the full suite. It reproduces on
a clean checkout, so it predates this work — some earlier suite establishes state
(an adapter install or a task-local) that it depends on and does not set itself.
Harmless today because CI runs everything; misleading the first time someone
filters down to it.
