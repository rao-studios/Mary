//
//  LifeCalibrationTests.swift
//  MaryRuntimeTests
//
//  WHAT: The row the Life sheet draws for one discipline.
//  OUT:  LifeCalibration
//

import Foundation
import Testing
import MaryBrain
import MaryFoundation
@testable import MaryRuntime

@Suite struct LifeCalibrationTests {

    private let anchor = Date(timeIntervalSince1970: 1_787_821_200)

    private func episode(
        lane: String = "dual", ability: AbilityID = .writing, at time: Date? = nil
    ) -> BehavioralEpisode {
        BehavioralEpisode(
            id: UUID(),
            openedAt: time ?? anchor,
            sealedAt: time ?? anchor,
            sealedReason: .completed,
            input: BehavioralInput(query: "type this"),
            provenance: EpisodeProvenance(engine: "local", lane: lane, appVersion: "test"),
            abilityTargets: [AbilityThreadTarget(abilityID: ability, paradigm: .discipline)])
    }

    private func slot(
        ready: Bool = true, training: Bool = false, pairCount: Int = 24, generation: Int = 1
    ) -> LifeLoRASlot {
        LifeLoRASlot(
            abilityID: .writing,
            generation: generation,
            pairCount: pairCount,
            artifactPath: "/tmp/writing",
            schemaJSON: Data(),
            ready: ready,
            trainedAt: anchor,
            training: training,
            modelID: "test-model",
            cid: "cid-one")
    }

    private func snapshot(
        episodes: [BehavioralEpisode],
        slots: [AbilityID: LifeLoRASlot] = [:],
        ticks: [AbilityID: LifeTrainTick] = [:],
        reachable: Bool = true,
        paused: Bool = false
    ) -> LifeCalibrationSnapshot {
        LifeCalibration.snapshot(
            disciplines: [(id: .writing, title: "Writing")],
            episodes: episodes,
            slots: slots,
            ticks: ticks,
            tails: [:],
            fleetReachable: reachable,
            trainingPaused: paused)
    }

    @Test func anUntrainedDisciplineCollectsTowardTheFirstAdapter() {
        let rows = snapshot(episodes: [episode(), episode()]).rows
        #expect(rows.count == 1)
        #expect(rows[0].phase == .collecting)
        #expect(rows[0].completedCount == 2)
        #expect(rows[0].fill.goal == 24)
        #expect(rows[0].caption == "2 of 24 turns")
    }

    /// The bar counts the user's turns. Mary's own idle episodes would fill
    /// it on their own — see LifeTrainPolicyTests.
    @Test func maryOwnIdleEpisodesDoNotFillTheBar() {
        let rows = snapshot(episodes: [
            episode(),
            episode(lane: EpisodeProvenance.proactiveLane),
        ]).rows
        #expect(rows[0].completedCount == 1)
    }

    @Test func aTrainedDisciplineReadsAsReady() {
        let rows = snapshot(episodes: [], slots: [.writing: slot(generation: 2)]).rows
        #expect(rows[0].phase == .ready)
        #expect(rows[0].caption == "ready · gen 2 · 24 pairs")
        #expect(rows[0].displayFraction == 1)
    }

    @Test func fleetSayingTrainingWinsOverEverything() {
        let rows = snapshot(episodes: [], slots: [.writing: slot(training: true)]).rows
        #expect(rows[0].phase == .training)
        #expect(rows[0].caption == "training")
    }

    @Test func aStreamedStepReadsAsTrainingWithItsLoss() {
        let rows = snapshot(
            episodes: [],
            slots: [.writing: slot()],
            ticks: [.writing: LifeTrainTick(
                stage: "step", iteration: 12, loss: 0.5, message: "")]).rows
        #expect(rows[0].phase == .training)
        #expect(rows[0].caption == "training · step 12 · loss 0.50")
    }

    @Test func aFinishedTickIsNotStillTraining() {
        let rows = snapshot(
            episodes: [],
            slots: [.writing: slot()],
            ticks: [.writing: LifeTrainTick(
                stage: "finished", iteration: 40, loss: 0.1, message: "")]).rows
        #expect(rows[0].phase != .training)
    }

    /// New turns are counted from when the adapter trained, not by
    /// subtracting its pairs — a run learns from a fixed window.
    @Test func afterAPublishTheBarCountsOnlyNewTurns() {
        let before = (0..<24).map { _ in episode(at: anchor.addingTimeInterval(-60)) }
        let after = (0..<6).map { _ in episode(at: anchor.addingTimeInterval(60)) }
        let rows = snapshot(
            episodes: before + after, slots: [.writing: slot(pairCount: 24)]).rows
        #expect(rows[0].fill.filled == 6)
        #expect(rows[0].fill.goal == 12)
        #expect(rows[0].caption == "6 of 12 since gen 1")
    }

    /// Life off: a full window holds at its goal and says it is waiting.
    @Test func aFullWindowWithLifeOffSaysItIsPaused() {
        let episodes = (0..<30).map { _ in episode() }
        let row = snapshot(episodes: episodes, paused: true).rows[0]
        #expect(row.fill.filled == 24)
        #expect(row.caption == "24 of 24 turns · paused")
        #expect(snapshot(episodes: episodes).rows[0].caption == "24 of 24 turns")
    }

    @Test func anUnreachableFleetIsCarriedOnTheSnapshot() {
        #expect(!snapshot(episodes: [], reachable: false).fleetReachable)
    }

    @Test func expertisePackagesNeverGetARow() {
        let rows = LifeCalibration.snapshot(
            disciplines: [],
            episodes: [episode()],
            slots: [:], ticks: [:], tails: [:], fleetReachable: true).rows
        #expect(rows.isEmpty)
    }
}
