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
        lane: String = "dual", ability: AbilityID = .writing
    ) -> BehavioralEpisode {
        BehavioralEpisode(
            id: UUID(),
            openedAt: anchor,
            sealedAt: anchor,
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
        reachable: Bool = true
    ) -> LifeCalibrationSnapshot {
        LifeCalibration.snapshot(
            disciplines: [(id: .writing, title: "Writing")],
            episodes: episodes,
            slots: slots,
            ticks: ticks,
            tails: [:],
            fleetReachable: reachable)
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

    @Test func afterAPublishTheBarCountsOnlyNewTurns() {
        let episodes = (0..<30).map { _ in episode() }
        let rows = snapshot(episodes: episodes, slots: [.writing: slot(pairCount: 24)]).rows
        #expect(rows[0].fill.filled == 6)
        #expect(rows[0].fill.goal == 12)
        #expect(rows[0].caption == "6 of 12 since gen 1")
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
