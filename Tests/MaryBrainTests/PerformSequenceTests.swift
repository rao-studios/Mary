//
//  PerformSequenceTests.swift
//  MaryBrainTests
//
//  THE DOOR A FUTURE MODEL'S PLAN WALKS THROUGH, tested now while it is still
//  cheap to change.
//
//  `perform(sequence:)` is plumbing — nothing user-facing calls it. It is
//  tested anyway, and early, because the behavioral codec's whole claim is
//  that `BehavioralAction` is the EMIT shape as well as the observed one: a
//  model trained on episodes emits a sequence of the objects it was shown.
//  Discovering later that a recorded action cannot be replayed would mean the
//  dataset had been describing something Mary cannot do — and by then there
//  would be a year of it.
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct PerformSequenceTests {

    /// Answers from a table and remembers what it was asked, in order.
    final class Sequencer: AbilityDispatching, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var dispatched: [(name: String, arguments: String)] = []
        var failing: Set<String> = []
        var blocking: Set<String> = []

        var schemas: [ModelSkillSchema] { [] }
        var schemaCount: Int { 0 }
        var abilityRosterTrace: AbilityRosterTrace { AbilityRosterTrace() }
        var abilitySnapshot: AbilityRuntimeSnapshot {
            AbilityRuntimeSnapshot(records: [], validation: AbilityPackageValidation(), adapterManifests: [])
        }
        var applicationProfiles: [ApplicationProfile] { [] }
        var focusedApplicationID: String? { nil }
        var hasPendingSkillConfirmation: Bool { false }
        var pendingSkillConfirmationID: UUID? { nil }
        var pendingSkillConfirmationPreview: String? { nil }
        func beginTurn() {}
        func skillReference(for name: String) -> AbilitySkillReference? { nil }

        func dispatch(name: String, argumentsJSON: String, runID: String? = nil) async -> SkillOutcome {
            // The lock is taken in a SYNCHRONOUS helper: NSLock is unavailable
            // from an async context because a suspension while holding it
            // deadlocks, and nothing here needs to suspend under it.
            let (fails, blocks) = note(name, argumentsJSON)
            if blocks {
                return SkillOutcome(
                    ok: false, summary: "not allowed here", status: .blocked)
            }
            return SkillOutcome(
                ok: !fails,
                summary: fails ? "didn't work" : "done",
                status: fails ? .failed : .succeeded)
        }

        private func note(_ name: String, _ arguments: String) -> (Bool, Bool) {
            lock.lock(); defer { lock.unlock() }
            dispatched.append((name, arguments))
            return (failing.contains(name), blocking.contains(name))
        }
    }

    private func action(_ intention: String, _ argumentsJSON: String = "{}") -> BehavioralAction {
        BehavioralAction(
            intention: intention,
            argumentsJSON: argumentsJSON,
            skill: AbilitySkillReference(
                packageID: PackageID(rawValue: "writing")!,
                packageVersion: SemanticVersion("1.0.0"),
                abilityID: .writing,
                abilityTitle: "Writing",
                abilityTint: "blue",
                skillID: SkillID(rawValue: "write")!,
                skillTitle: "Write",
                invocationName: intention))
    }

    @Test func everyActionRunsInOrderAndReturnsARecordEach() async {
        let dispatcher = Sequencer()
        let records = await dispatcher.perform(
            sequence: [action("create_document"), action("type_at_cursor"), action("save")],
            episodeID: nil)

        #expect(dispatcher.dispatched.map(\.name)
                == ["create_document", "type_at_cursor", "save"])
        #expect(records.count == 3)
        #expect(records.allSatisfy { $0.disposition == .succeeded })
    }

    /// THE ARGUMENTS GO THROUGH UNTOUCHED. A replay that re-encoded them would
    /// be replaying a paraphrase, and the canonical bytes are the only thing
    /// making a recorded action reproducible at all.
    @Test func theRecordedArgumentsReachTheBindingByteForByte() async {
        let dispatcher = Sequencer()
        let canonical = #"{"place":"quill","text":"a, b"}"#
        _ = await dispatcher.perform(
            sequence: [action("type_at_cursor", canonical)], episodeID: nil)

        #expect(dispatcher.dispatched.first?.arguments == canonical)
    }

    /// A PLAN WHOSE SECOND STEP FAILED HAS NO BUSINESS RUNNING ITS FIFTH.
    /// The records cover what actually ran, so the caller can see where it
    /// stopped without inferring it from a count.
    @Test func aFailedStepStopsTheSequence() async {
        let dispatcher = Sequencer()
        dispatcher.failing = ["type_at_cursor"]
        let records = await dispatcher.perform(
            sequence: [action("create_document"), action("type_at_cursor"), action("save")],
            episodeID: nil)

        #expect(dispatcher.dispatched.map(\.name) == ["create_document", "type_at_cursor"])
        #expect(records.count == 2)
        #expect(records.last?.disposition == .failed)
    }

    /// BLOCKED IS NOT SUCCEEDED EITHER. A refusal is a settled outcome, and a
    /// plan that continues past one is a plan acting on a permission it was
    /// just denied.
    @Test func aBlockedStepStopsTheSequenceToo() async {
        let dispatcher = Sequencer()
        dispatcher.blocking = ["create_document"]
        let records = await dispatcher.perform(
            sequence: [action("create_document"), action("type_at_cursor")],
            episodeID: nil)

        #expect(dispatcher.dispatched.map(\.name) == ["create_document"])
        #expect(records.last?.disposition == .blocked)
    }

    @Test func anEmptySequenceRunsNothingAndReturnsNothing() async {
        let dispatcher = Sequencer()
        let records = await dispatcher.perform(sequence: [], episodeID: nil)
        #expect(dispatcher.dispatched.isEmpty)
        #expect(records.isEmpty)
    }

    /// EVERY RECORD GETS ITS OWN ID, because a run id is what a chip, a log
    /// row and a dataset row correlate on — and two actions sharing one would
    /// make the same edit appear twice, or once.
    @Test func eachReplayedActionGetsADistinctRunID() async {
        let dispatcher = Sequencer()
        let records = await dispatcher.perform(
            sequence: [action("a"), action("b"), action("c")], episodeID: nil)
        #expect(Set(records.map(\.id)).count == 3)
    }

    /// THE ROUND TRIP THAT MATTERS: what a sequence produces is the same shape
    /// a sequence is made of, so an episode's output can be fed back in.
    @Test func theRecordsAReplayProducesCanThemselvesBeReplayed() async {
        let first = Sequencer()
        let produced = await first.perform(
            sequence: [action("create_document"), action("save")], episodeID: nil)

        let second = Sequencer()
        let again = await second.perform(
            sequence: produced.map(\.action), episodeID: nil)

        #expect(second.dispatched.map(\.name) == first.dispatched.map(\.name))
        #expect(again.count == produced.count)
    }
}
