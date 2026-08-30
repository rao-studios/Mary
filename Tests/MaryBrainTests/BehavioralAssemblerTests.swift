//
//  BehavioralAssemblerTests.swift
//  MaryBrainTests
//
//  WHICH TURN AN ACTION BELONGS TO — every way that question can be asked.
//
//  The assembler is pure bookkeeping over a lock, which makes it exactly the
//  kind of thing worth testing directly: the failures it can have are not
//  crashes, they are actions filed under the wrong turn, and an action filed
//  under the wrong turn is invisible until somebody reads the dataset a year
//  later and finds a query that never asked for what follows it.
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryBrain

@Suite struct BehavioralAssemblerTests {

    /// Collects sealed episodes in seal order.
    final class Recorder: BehavioralRecording, @unchecked Sendable {
        private let lock = NSLock()
        private var _episodes: [BehavioralEpisode] = []
        var episodes: [BehavioralEpisode] {
            lock.lock(); defer { lock.unlock() }
            return _episodes
        }
        func append(_ episode: BehavioralEpisode) async {
            // NOT `lock.lock()`: NSLock is unavailable from an async context
            // because a suspension while holding it deadlocks. The append is
            // synchronous, so it goes in a nonisolated helper.
            store(episode)
        }

        private func store(_ episode: BehavioralEpisode) {
            lock.lock(); _episodes.append(episode); lock.unlock()
        }
        /// The assembler hands off detached AT `.utility`, so a test that just
        /// sealed has to let that task run.
        ///
        /// THE BUDGET IS WALL-CLOCK, not a sleep count, and that distinction
        /// cost a green run to learn. A fixed 200 × 1ms loop is a 200ms budget
        /// only on an idle machine; run inside the one-process bundle with a
        /// hundred suites in flight, a `.utility` task is starved behind all of
        /// them and 200 sleeps stretch into seconds while still expiring too
        /// early. The failure looked like a lost episode — in two tests at once,
        /// one of which then indexed an empty array and took the whole bundle
        /// down with it. A generous deadline costs a passing test nothing: it
        /// returns the instant the episodes arrive.
        func settle(expecting count: Int, within seconds: TimeInterval = 10) async {
            let deadline = Date().addingTimeInterval(seconds)
            while episodes.count < count, Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
    }

    private let provenance = EpisodeProvenance(
        engine: "local", lane: "dual", appVersion: "test")

    /// One reference, shared: this suite is about WHICH TURN an action lands
    /// in, and varying the reference would only add noise to that question.
    private static let reference = AbilitySkillReference(
        packageID: PackageID(rawValue: "writing")!,
        packageVersion: SemanticVersion("1.0.0"),
        abilityID: .writing,
        abilityTitle: "Writing",
        abilityTint: "blue",
        skillID: SkillID(rawValue: "write")!,
        skillTitle: "Write",
        invocationName: "write")

    private func record(
        _ intention: String, _ status: SkillRunStatus = .succeeded, id: String = UUID().uuidString
    ) -> BehavioralActionRecord {
        BehavioralActionRecord(
            id: id,
            action: BehavioralAction(
                intention: intention,
                argumentsJSON: "{}",
                skill: Self.reference),
            disposition: BehavioralDisposition(status),
            summary: "ok",
            startedAt: Date())
    }

    // MARK: - The happy path

    @Test func oneTurnBecomesOneSealedEpisodeCarryingItsActions() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()

        assembler.openEpisode(id: turn, query: "tidy the note", provenance: provenance)
        assembler.append(record("read_document"))
        assembler.append(record("replace_passage"))
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes.count == 1)
        let episode = recorder.episodes[0]
        #expect(episode.id == turn)
        #expect(episode.input.query == "tidy the note")
        #expect(episode.sealedReason == .completed)
        #expect(episode.output.actions.map(\.action.intention)
                == ["read_document", "replace_passage"])
    }

    /// THE ORDER IS THE SEQUENCE. A future model emits actions in order and is
    /// trained on episodes; if the recorded order were the order they happened
    /// to settle in rather than the order they were dispatched, the dataset
    /// would teach a plan nobody made.
    @Test func actionsKeepTheOrderTheyWereAppendedIn() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()
        assembler.openEpisode(id: turn, query: "q", provenance: provenance)
        for name in ["a", "b", "c", "d"] { assembler.append(record(name)) }
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes[0].output.actions.map(\.action.intention)
                == ["a", "b", "c", "d"])
    }

    // MARK: - The input half

    @Test func aStagedCaptureIsClaimedOntoTheEpisodeThatFollowsIt() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()

        assembler.openEpisode(id: turn, query: "q", provenance: provenance)
        assembler.stageCapture(AmbientCapture(mode: "relevance"))
        assembler.claimStagedCapture(forEpisode: turn)
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes[0].input.ambient?.mode == "relevance")
    }

    /// A STALE STAGE IS DROPPED, NOT CARRIED. It describes the context earned
    /// by a query that was never asked, and attaching it to the next turn
    /// would make that turn's row claim it saw something it never saw.
    @Test func aStageLeftOverFromAnAbandonedTurnNeverReachesTheNextOne() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let abandoned = UUID(), next = UUID()

        assembler.openEpisode(id: abandoned, query: "first", provenance: provenance)
        assembler.stageCapture(AmbientCapture(mode: "stale"))
        // The first turn never claims; a second one opens.
        assembler.openEpisode(id: next, query: "second", provenance: provenance)
        assembler.claimStagedCapture(forEpisode: next)
        assembler.seal(next, reason: .completed)
        await recorder.settle(expecting: 2)

        let second = recorder.episodes.first { $0.id == next }
        #expect(second?.input.ambient == nil,
                "the abandoned turn's capture reached the next turn")
    }

    /// ABSENT IS NOT EMPTY, one level up: no capture at all means no prompt
    /// was ever built (a deterministic decision path), while an empty one
    /// means a prompt was built and the store held nothing.
    @Test func noPromptBuiltLeavesTheCaptureAbsentRatherThanEmpty() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()
        assembler.openEpisode(id: turn, query: "yes", provenance: provenance)
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes[0].input.ambient == nil)
    }

    // MARK: - Supersede

    /// An open episode found at open time is SEALED, not dropped — whatever it
    /// already did really happened.
    @Test func openingOverAnOpenEpisodeSealsTheOldOneSuperseded() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let first = UUID(), second = UUID()

        assembler.openEpisode(id: first, query: "first", provenance: provenance)
        assembler.append(record("already_ran"))
        assembler.openEpisode(id: second, query: "second", provenance: provenance)
        await recorder.settle(expecting: 1)

        let sealed = recorder.episodes[0]
        #expect(sealed.id == first)
        #expect(sealed.sealedReason == .superseded)
        #expect(sealed.output.actions.count == 1,
                "the superseded turn's real action was thrown away")
    }

    /// THE FIRST REASON WINS. A turn cancelled by a barge-in and then caught
    /// by the quit flush was cancelled, not quit.
    @Test func aSecondSealDoesNotOverwriteTheFirstReason() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        var episode = BehavioralEpisode(
            id: UUID(), openedAt: Date(),
            input: BehavioralInput(query: "q"), provenance: provenance)
        episode.seal(.cancelled)
        episode.seal(.appQuit)
        #expect(episode.sealedReason == .cancelled)
        _ = assembler
        _ = recorder
    }

    // MARK: - Detached routines

    /// THE LAST ROUTINE OUT SEALS. Until then the episode stays open, so the
    /// routine's own actions land in the turn that ordered them rather than in
    /// whatever turn happens to be open when they finish.
    @Test func anEpisodeWithARunningRoutineDefersItsSeal() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()

        assembler.openEpisode(id: turn, query: "go and do the thing", provenance: provenance)
        assembler.noteRoutineDetached(origin: turn)
        assembler.seal(turn, reason: .completed)
        #expect(recorder.episodes.isEmpty, "sealed while a routine was still running")

        // The routine's work lands AFTER the spoken reply ended.
        assembler.append(record("routine_action"), toEpisode: turn)
        assembler.noteRoutineSettled(origin: turn)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes.count == 1)
        #expect(recorder.episodes[0].sealedReason == .completed)
        #expect(recorder.episodes[0].output.actions.map(\.action.intention)
                == ["routine_action"])
    }

    @Test func twoRoutinesBothHaveToSettleBeforeTheEpisodeSeals() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()

        assembler.openEpisode(id: turn, query: "two things", provenance: provenance)
        assembler.noteRoutineDetached(origin: turn)
        assembler.noteRoutineDetached(origin: turn)
        assembler.seal(turn, reason: .completed)
        assembler.noteRoutineSettled(origin: turn)
        #expect(recorder.episodes.isEmpty, "sealed with one routine still running")

        assembler.noteRoutineSettled(origin: turn)
        await recorder.settle(expecting: 1)
        #expect(recorder.episodes.count == 1)
    }

    // MARK: - Records with nowhere to go

    /// A RECORD NAMING A CLOSED EPISODE IS COUNTED, NOT GUESSED AT. Filing it
    /// under the open turn instead would put a routine's action in a
    /// conversation it had nothing to do with.
    @Test func aRecordForTheWrongEpisodeIsDroppedAndCounted() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID(), stranger = UUID()

        assembler.openEpisode(id: turn, query: "q", provenance: provenance)
        assembler.append(record("mine"))
        assembler.append(record("not_mine"), toEpisode: stranger)
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes[0].output.actions.map(\.action.intention) == ["mine"])
        #expect(assembler.droppedRecords == 1)
    }

    @Test func aRecordWithNoOpenEpisodeIsDroppedAndCounted() {
        let assembler = BehavioralAssembler()
        assembler.append(record("orphan"))
        #expect(assembler.droppedRecords == 1)
    }

    // MARK: - Quit

    @Test func theQuitFlushSealsWhateverIsOpen() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()

        assembler.openEpisode(id: turn, query: "mid-turn", provenance: provenance)
        assembler.append(record("landed_in_time"))
        assembler.flushOpenEpisodes()
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes[0].sealedReason == .appQuit)
        #expect(recorder.episodes[0].output.actions.count == 1)
    }

    @Test func theQuitFlushWithNothingOpenRecordsNothing() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        assembler.flushOpenEpisodes()
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(recorder.episodes.isEmpty)
    }

    // MARK: - Chaining

    @Test func priorEpisodeIDChainsTurnsInsteadOfEmbeddingHistory() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let first = UUID(), second = UUID()

        assembler.openEpisode(id: first, query: "one", provenance: provenance)
        assembler.seal(first, reason: .completed)
        assembler.openEpisode(
            id: second, query: "two", priorEpisodeID: first, provenance: provenance)
        assembler.seal(second, reason: .completed)
        await recorder.settle(expecting: 2)

        let tail = recorder.episodes.first { $0.id == second }
        #expect(tail?.input.priorEpisodeID == first)
    }

    // MARK: - No recorder

    /// AN ASSEMBLER WITH NOWHERE TO SEAL IS A WORKING ASSEMBLER. Recording is
    /// a setting, and switching it off must not change what a turn does.
    @Test func anAssemblerWithNoRecorderStillRunsTheWholeLifecycle() {
        let assembler = BehavioralAssembler()
        let turn = UUID()
        assembler.openEpisode(id: turn, query: "q", provenance: provenance)
        assembler.append(record("acted"))
        #expect(assembler.openEpisodeID == turn)
        assembler.seal(turn, reason: .completed)
        #expect(assembler.openEpisodeID == nil)
        #expect(assembler.droppedRecords == 0)
    }

    @Test func abilityTargetsStampTheOpenEpisodeBeforeSeal() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()
        let coding = AbilityTotemTarget(abilityID: .coding, paradigm: .discipline)

        assembler.openEpisode(id: turn, query: "tidy", provenance: provenance)
        assembler.noteAbilityTargets([coding], forEpisode: turn)
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)

        #expect(recorder.episodes[0].abilityTargets == [coding])
    }

    @Test func abilityTargetsForTheWrongEpisodeAreIgnored() async {
        let recorder = Recorder()
        let assembler = BehavioralAssembler(recorder: recorder)
        let turn = UUID()
        assembler.openEpisode(id: turn, query: "q", provenance: provenance)
        assembler.noteAbilityTargets(
            [AbilityTotemTarget(abilityID: .coding, paradigm: .discipline)],
            forEpisode: UUID())
        assembler.seal(turn, reason: .completed)
        await recorder.settle(expecting: 1)
        #expect(recorder.episodes[0].abilityTargets.isEmpty)
    }
}
