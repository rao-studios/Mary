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

    @Test func progressFillsTwentyFourThenTwelve() {
        let empty = LifeTrainPolicy.progress(completedCount: 0, trainedPairCount: nil)
        #expect(empty.filled == 0)
        #expect(empty.goal == 24)
        #expect(empty.fraction == 0)

        let twentyThree = LifeTrainPolicy.progress(completedCount: 23, trainedPairCount: nil)
        #expect(twentyThree.filled == 23)
        #expect(twentyThree.goal == 24)

        let first = LifeTrainPolicy.progress(completedCount: 24, trainedPairCount: nil)
        #expect(first.filled == 24)
        #expect(first.goal == 24)
        #expect(first.fraction == 1)

        let idle = LifeTrainPolicy.progress(completedCount: 24, trainedPairCount: 24)
        #expect(idle.filled == 0)
        #expect(idle.goal == 12)
        #expect(idle.fraction == 0)

        let eleven = LifeTrainPolicy.progress(completedCount: 35, trainedPairCount: 24)
        #expect(eleven.filled == 11)
        #expect(eleven.goal == 12)

        let twelve = LifeTrainPolicy.progress(completedCount: 36, trainedPairCount: 24)
        #expect(twelve.filled == 12)
        #expect(twelve.goal == 12)
        #expect(twelve.fraction == 1)
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
