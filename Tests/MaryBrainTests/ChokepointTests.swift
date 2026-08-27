//
//  ChokepointTests.swift
//  MaryBrainTests
//
//  ONE DISPATCH, ONE RECORD — for every shape an outcome can take.
//
//  The chokepoint's value is entirely in its completeness. A recording site
//  that catches the acts that RAN and misses the refusals produces a dataset
//  in which every request was granted, which is a false picture of the system
//  and a worse one to learn from. So the cases here are deliberately the
//  boring ones: a read, a miss, a failure, a refusal, a park.
//
//  AND THE DIVERGENCE, PINNED DEAD. The ledger this replaces took its
//  reference from the STATIC snapshot while the transcript chip took the
//  TURN-PATCHED one, so the log and the chip printed different providers for
//  the same act. `theRecordedReferenceIsTheTurnAccurateOne` is the regression
//  test for a bug that can only come back by someone reintroducing a second
//  composition site.
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryAdapters
@testable import MaryBrain

@Suite struct ChokepointTests {

    /// A binding that answers however the test asks it to.
    private func adapter(
        _ name: String,
        access: SkillAccessPolicy = .read,
        outcome: @escaping @Sendable () -> SkillOutcome
    ) -> any MaryAdapter {
        ScriptedAdapter(name: "scripted", bindings: [
            SkillBinding(
                name: name,
                description: "A fixture.",
                parameters: [],
                access: access,
                backing: .native { _, _ in outcome() }),
        ])
    }

    private struct ScriptedAdapter: MaryAdapter {
        let name: String
        let summary = "A fixture."
        let bindings: [SkillBinding]
        var skillBindings: [SkillBinding] { bindings }
    }

    private func runtime(
        _ adapters: [any MaryAdapter], log: AbilityExecutionLog,
        behavior: BehavioralAssembler? = nil
    ) -> AbilityRuntime {
        AbilityRuntime(
            plugins: adapters,
            executionLog: log,
            behavior: behavior,
            ambient: AmbientContextStore(),
            passages: PassageRegistry(),
            containers: ContainerRegistry(),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
    }

    // MARK: - Every outcome shape lands exactly once

    @Test(arguments: [
        ("succeeded", SkillOutcome(ok: true, summary: "done"), BehavioralDisposition.succeeded),
        ("failed", SkillOutcome(ok: false, summary: "nope", status: .failed), .failed),
        ("blocked", SkillOutcome(ok: false, summary: "not here", status: .blocked), .blocked),
        ("cancelled", SkillOutcome(ok: false, summary: "stopped", status: .cancelled), .cancelled),
    ])
    func everyOutcomeShapeProducesExactlyOneRecord(
        _ label: String, _ outcome: SkillOutcome, _ expected: BehavioralDisposition
    ) async {
        let log = AbilityExecutionLog()
        let runtime = runtime([adapter("act") { outcome }], log: log)
        _ = await runtime.dispatch(name: "act", argumentsJSON: "{}")

        let rows = log.entries()
        #expect(rows.count == 1, "\(label) produced \(rows.count) rows")
        #expect(rows.first?.disposition == expected)
        #expect(rows.first?.action.intention == "act")
    }

    /// A MISS IS NOT A FAILURE, and the row has to keep them apart. A search
    /// that ran and found nothing is `ok: true, foundNothing: true` — correct,
    /// because `ok: false` would make the turn speak the miss as a breakage.
    /// The row that renders it green and identical to a successful edit is
    /// then the one row a person opened the log to understand.
    @Test func aFoundNothingReadIsRecordedAsAMissRatherThanASuccess() async {
        let log = AbilityExecutionLog()
        let runtime = runtime([
            adapter("find") {
                SkillOutcome(ok: true, summary: "no such passage", foundNothing: true)
            },
        ], log: log)
        _ = await runtime.dispatch(name: "find", argumentsJSON: "{}")

        let row = log.entries().first
        #expect(row?.disposition == .succeeded)
        #expect(row?.foundNothing == true)
    }

    /// A NAME NOTHING ANSWERS IS STILL AN ACT THE MODEL TOOK. It gets a row
    /// too — the dataset's whole value is that it shows what was attempted.
    @Test func anUnknownSkillIsRecordedRatherThanSilentlyDropped() async {
        let log = AbilityExecutionLog()
        let runtime = runtime([adapter("act") { SkillOutcome(ok: true, summary: "x") }], log: log)
        _ = await runtime.dispatch(name: "no_such_skill", argumentsJSON: "{}")

        #expect(log.entries().count == 1)
        #expect(log.entries().first?.action.intention == "no_such_skill")
        #expect(log.entries().first?.disposition != .succeeded)
    }

    // MARK: - The reference

    /// THE REGRESSION TEST FOR THE DIVERGENCE. What the ledger records is what
    /// `skillReference(for:)` answers — the turn-accurate reference the chip
    /// also renders — and not the static snapshot's.
    @Test func theRecordedReferenceIsTheTurnAccurateOne() async {
        let log = AbilityExecutionLog()
        let runtime = runtime([adapter("act") { SkillOutcome(ok: true, summary: "done") }], log: log)
        let expected = runtime.skillReference(for: "act")
        _ = await runtime.dispatch(name: "act", argumentsJSON: "{}")

        #expect(log.entries().first?.action.skill.invocationName == expected.invocationName)
        #expect(log.entries().first?.action.skill.adapterID == expected.adapterID)
    }

    /// AN OUTCOME THAT CARRIES ITS OWN REFERENCE WINS. That is how a
    /// confirmation replay keeps the binding the user actually approved,
    /// rather than the one the roster would choose now that focus has moved.
    @Test func anOutcomesOwnReferenceOutranksTheTurnsAnswer() async {
        let frozen = AbilitySkillReference(
            packageID: PackageID(rawValue: "frozen")!,
            packageVersion: SemanticVersion("1.0.0"),
            abilityID: .writing,
            abilityTitle: "Writing",
            abilityTint: "blue",
            skillID: SkillID(rawValue: "frozen-skill")!,
            skillTitle: "Frozen",
            invocationName: "frozen_at_park_time")
        let log = AbilityExecutionLog()
        let runtime = runtime([
            adapter("act") {
                SkillOutcome(ok: true, summary: "replayed", skillReference: frozen)
            },
        ], log: log)
        _ = await runtime.dispatch(name: "act", argumentsJSON: "{}")

        #expect(log.entries().first?.action.skill.invocationName == "frozen_at_park_time")
        // The INTENTION is still what was called — the reference says which
        // binding served it, and those are different questions.
        #expect(log.entries().first?.action.intention == "act")
    }

    // MARK: - Arguments

    /// KEY ORDER IS NOT MEANING. A model emits keys however it pleases, and
    /// two calls differing only in order are the same call — a dataset that
    /// records them as different strings cannot deduplicate or diff.
    @Test func argumentsAreRecordedInCanonicalKeyOrder() async {
        let log = AbilityExecutionLog()
        let runtime = runtime([adapter("act") { SkillOutcome(ok: true, summary: "x") }], log: log)
        _ = await runtime.dispatch(
            name: "act", argumentsJSON: #"{"zebra":"1","alpha":"2"}"#)

        #expect(log.entries().first?.action.argumentsJSON == #"{"alpha":"2","zebra":"1"}"#)
    }

    /// MALFORMED ARGUMENTS ARE KEPT AS THEY ARRIVED. Canonicalizing is a
    /// convenience; losing what the model actually sent is not.
    @Test func argumentsThatAreNotJSONSurviveVerbatim() async {
        let log = AbilityExecutionLog()
        let runtime = runtime([adapter("act") { SkillOutcome(ok: true, summary: "x") }], log: log)
        _ = await runtime.dispatch(name: "act", argumentsJSON: "not json at all")

        #expect(log.entries().first?.action.argumentsJSON == "not json at all")
    }

    // MARK: - The assembler sees the same records

    @Test func theTurnsEpisodeReceivesEveryRecordTheLedgerDoes() async {
        let log = AbilityExecutionLog()
        let recorder = BehavioralAssemblerTests.Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()
        assembler.openEpisode(
            id: turn, query: "do three things",
            provenance: EpisodeProvenance(engine: "local", lane: "dual", appVersion: "test"))

        let runtime = runtime(
            [adapter("act") { SkillOutcome(ok: true, summary: "done") }],
            log: log, behavior: assembler)
        for _ in 0..<3 {
            _ = await runtime.dispatch(name: "act", argumentsJSON: "{}")
        }
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(log.entries().count == 3)
        #expect(recorder.episodes.first?.output.actions.count == 3)
        // THE SAME VALUES, not merely the same count: one composition site.
        #expect(Set(log.entries().map(\.id))
                == Set(recorder.episodes[0].output.actions.map(\.id)))
    }

    /// EVERY RUN ID IS ITS OWN. A chip, a log row and a dataset row correlate
    /// on it, and two acts sharing one make the same edit appear twice — or
    /// once.
    @Test func repeatedDispatchesOfOneSkillGetDistinctRunIDs() async {
        let log = AbilityExecutionLog()
        let runtime = runtime([adapter("act") { SkillOutcome(ok: true, summary: "x") }], log: log)
        for _ in 0..<4 { _ = await runtime.dispatch(name: "act", argumentsJSON: "{}") }

        #expect(Set(log.entries().map(\.id)).count == 4)
    }
}
