//
//  LifeTrainPolicyTests.swift
//  MaryFoundationTests
//
//  First train at 24 completed discipline episodes; retrain every +12.
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct LifeTrainPolicyTests {

    @Test func twentyThreeDoesNotTrainAndTwentyFourDoes() {
        #expect(!LifeTrainPolicy.shouldTrain(completedCount: 23, trainedPairCount: nil))
        #expect(LifeTrainPolicy.shouldTrain(completedCount: 24, trainedPairCount: nil))
    }

    @Test func retrainNeedsTwelveNewSinceLastPublish() {
        #expect(!LifeTrainPolicy.shouldTrain(completedCount: 35, trainedPairCount: 24))
        #expect(LifeTrainPolicy.shouldTrain(completedCount: 36, trainedPairCount: 24))
    }

    @Test func completedCountSkipsNonDisciplineAndUnsealedReasons() {
        var completed = BehaviorFixtures.typedIntoTextEdit
        completed.id = UUID()
        completed.abilityTargets = [
            AbilityTotemTarget(abilityID: .writing, paradigm: .discipline)
        ]

        var expertise = completed
        expertise.id = UUID()
        expertise.abilityTargets = [
            AbilityTotemTarget(abilityID: .writing, paradigm: .applicationExpertise)
        ]

        var cancelled = completed
        cancelled.id = UUID()
        cancelled.sealedReason = .cancelled

        var superseded = completed
        superseded.id = UUID()
        superseded.sealedReason = .superseded

        #expect(
            LifeTrainPolicy.completedCount(
                in: [completed, expertise, cancelled, superseded],
                abilityID: .writing) == 1)
    }

    @Test func trainingEpisodesPreferActedThenSilent() {
        var acted = BehaviorFixtures.typedIntoTextEdit
        acted.abilityTargets = [
            AbilityTotemTarget(abilityID: .writing, paradigm: .discipline)
        ]
        var silent = acted
        silent.id = UUID()
        silent.output.actions = []
        var onlySilent = silent
        onlySilent.id = UUID()

        let mixed = LifeTrainPolicy.trainingEpisodes(
            from: [silent, acted], abilityID: .writing)
        #expect(mixed.map(\.id) == [acted.id, silent.id])

        #expect(
            LifeTrainPolicy.trainingEpisodes(
                from: [onlySilent], abilityID: .writing).isEmpty)
    }
}
