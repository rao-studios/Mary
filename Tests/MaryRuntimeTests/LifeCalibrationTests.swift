//
//  LifeCalibrationTests.swift
//  MaryRuntimeTests
//
//  One row per installed discipline, even with no Fleet slot yet.
//  Expertise packages never appear. Ready-and-idle fills the bar.
//

import Foundation
import MaryBrain
import MaryFoundation
import MaryFoundationTestSupport
import Testing
@testable import MaryRuntime

@Suite struct LifeCalibrationTests {

    @Test func expertisePackagesDoNotAppearAndDisciplineNeedsNoSlot() {
        let packages = [
            PackageFixtures.minimalDiscipline,
            PackageFixtures.applicationExpertise,
        ]
        let disciplines = LifeCalibration.disciplines(in: packages)
        #expect(disciplines.map(\.id) == [AbilityID("tests.minimal")])
        #expect(disciplines.map(\.title) == ["Minimal"])

        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.id = UUID()
        episode.abilityTargets = [
            AbilityTotemTarget(abilityID: AbilityID("tests.minimal"), paradigm: .discipline)
        ]

        let snapshot = LifeCalibration.snapshot(
            disciplines: disciplines,
            episodes: [episode],
            slots: [:],
            ticks: [:],
            tails: [:],
            fleetReachable: true)
        #expect(snapshot.rows.count == 1)
        let row = snapshot.rows[0]
        #expect(row.completedCount == 1)
        #expect(row.pairCount == nil)
        #expect(row.ready == false)
        #expect(row.phase == .collecting)
        #expect(row.fill.goal == 24)
        #expect(row.fill.filled == 1)
        #expect(row.caption == "1 of 24 turns")
    }

    @Test func readyIdleShowsFullBarNotEmptyRetrainWindow() {
        let id = AbilityID("tests.minimal")
        let slot = LifeLoRASlot(
            abilityID: id,
            generation: 1,
            pairCount: 24,
            artifactPath: "/tmp/adapter.safetensors",
            schemaJSON: Data("{}".utf8),
            ready: true,
            trainedAt: Date(timeIntervalSince1970: 1_700_000_000),
            training: false,
            modelID: "mlx-community/Mistral-Nemo-Instruct-2407-4bit",
            cid: "cid-1")
        let snapshot = LifeCalibration.snapshot(
            disciplines: [(id, "Minimal")],
            episodes: completedEpisodes(24, ability: id),
            slots: [id: slot],
            ticks: [:],
            tails: [:],
            fleetReachable: true)
        let row = snapshot.rows[0]
        #expect(row.phase == .ready)
        #expect(row.fill.filled == 0)
        #expect(row.fill.goal == 12)
        #expect(row.displayFraction == 1)
        #expect(row.caption == "ready · gen 1 · 24 pairs")
        #expect(snapshot.readyCount == 1)
    }

    @Test func retrainWindowAndTrainingTick() {
        let id = AbilityID("tests.minimal")
        let slot = LifeLoRASlot(
            abilityID: id,
            generation: 1,
            pairCount: 24,
            artifactPath: "/tmp/adapter.safetensors",
            schemaJSON: Data(),
            ready: true)
        let collecting = LifeCalibration.snapshot(
            disciplines: [(id, "Minimal")],
            episodes: completedEpisodes(35, ability: id),
            slots: [id: slot],
            ticks: [:],
            tails: [:],
            fleetReachable: false)
        #expect(collecting.fleetReachable == false)
        #expect(collecting.rows[0].phase == .collecting)
        #expect(collecting.rows[0].fill.filled == 11)
        #expect(collecting.rows[0].fill.goal == 12)
        #expect(collecting.rows[0].caption == "11 of 12 since gen 1")

        let tick = LifeTrainTick(stage: "step", iteration: 40, loss: 0.12, message: "")
        let training = LifeCalibration.snapshot(
            disciplines: [(id, "Minimal")],
            episodes: completedEpisodes(36, ability: id),
            slots: [id: slot],
            ticks: [id: tick],
            tails: [id: [tick.line]],
            fleetReachable: true)
        #expect(training.rows[0].phase == .training)
        #expect(training.rows[0].caption == "training · step 40 · loss 0.12")
        #expect(training.isTraining)
        #expect(training.rows[0].logTail == ["step 40 · loss 0.12"])
    }

    private func completedEpisodes(_ count: Int, ability: AbilityID) -> [BehavioralEpisode] {
        (0..<count).map { _ in
            var episode = BehaviorFixtures.typedIntoTextEdit
            episode.id = UUID()
            episode.abilityTargets = [
                AbilityTotemTarget(abilityID: ability, paradigm: .discipline)
            ]
            return episode
        }
    }
}
