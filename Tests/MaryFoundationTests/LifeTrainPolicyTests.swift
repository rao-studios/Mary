//
//  LifeTrainPolicyTests.swift
//  MaryFoundationTests
//
//  WHAT: When a discipline has earned a LoRA, and whose turns count.
//  OUT:  LifeTrainPolicy
//  PIN:  The lane exclusion is the point of this suite. Everything else here
//        is arithmetic; that one is a feedback loop.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct LifeTrainPolicyTests {

    private let anchor = Date(timeIntervalSince1970: 1_787_821_200)

    private func episode(
        lane: String = "dual",
        sealed: EpisodeSealReason? = .completed,
        ability: AbilityID = .writing,
        paradigm: AbilityParadigm = .discipline
    ) -> BehavioralEpisode {
        BehavioralEpisode(
            id: UUID(),
            openedAt: anchor,
            sealedAt: anchor,
            sealedReason: sealed,
            input: BehavioralInput(query: "type this"),
            provenance: EpisodeProvenance(engine: "local", lane: lane, appVersion: "test"),
            abilityTargets: [AbilityThreadTarget(abilityID: ability, paradigm: paradigm)])
    }

    // MARK: - The threshold

    @Test func theFirstAdapterNeedsTwentyFourTurns() {
        #expect(!LifeTrainPolicy.shouldTrain(completedCount: 23, trainedPairCount: nil))
        #expect(LifeTrainPolicy.shouldTrain(completedCount: 24, trainedPairCount: nil))
    }

    @Test func aRetrainNeedsTwelveMoreThanWasPublished() {
        #expect(!LifeTrainPolicy.shouldTrain(completedCount: 35, trainedPairCount: 24))
        #expect(LifeTrainPolicy.shouldTrain(completedCount: 36, trainedPairCount: 24))
    }

    @Test func progressFillsTowardTheFirstAdapter() {
        let fill = LifeTrainPolicy.progress(completedCount: 12, trainedPairCount: nil)
        #expect(fill.filled == 12)
        #expect(fill.goal == 24)
        #expect(fill.fraction == 0.5)
    }

    @Test func progressAfterPublishCountsOnlyTheNewTurns() {
        let fill = LifeTrainPolicy.progress(completedCount: 30, trainedPairCount: 24)
        #expect(fill.filled == 6)
        #expect(fill.goal == 12)
    }

    @Test func progressNeverOverfillsItsBar() {
        let fill = LifeTrainPolicy.progress(completedCount: 400, trainedPairCount: 24)
        #expect(fill.filled == 12)
        #expect(fill.fraction == 1)
    }

    // MARK: - Whose turns count

    @Test func aCompletedUserTurnCounts() {
        #expect(LifeTrainPolicy.completedCount(
            in: [episode()], abilityID: .writing) == 1)
    }

    /// THE FEEDBACK LOOP. Mary's own idle episodes are sealed `.completed`
    /// and filed under the same ability group as a real turn. Counting them
    /// would let a quiet afternoon trip a retrain on the model's own output.
    @Test func maryOwnIdleEpisodesDoNotCount() {
        let episodes = [
            episode(),
            episode(lane: EpisodeProvenance.proactiveLane),
            episode(lane: EpisodeProvenance.proactiveLane),
        ]
        #expect(LifeTrainPolicy.completedCount(in: episodes, abilityID: .writing) == 1)
    }

    @Test func anInterruptedTurnDoesNotCount() {
        let episodes = [
            episode(sealed: .superseded),
            episode(sealed: .cancelled),
            episode(sealed: .appQuit),
        ]
        #expect(LifeTrainPolicy.completedCount(in: episodes, abilityID: .writing) == 0)
    }

    @Test func anotherDisciplinesTurnDoesNotCount() {
        #expect(LifeTrainPolicy.completedCount(
            in: [episode(ability: .coding)], abilityID: .writing) == 0)
    }

    /// Expertise never gets a LoRA, so an expertise target is not a turn in
    /// the discipline's window either.
    @Test func anExpertiseTargetDoesNotCount() {
        #expect(LifeTrainPolicy.completedCount(
            in: [episode(paradigm: .applicationExpertise)], abilityID: .writing) == 0)
    }

    @Test func theLaneIsNamedOnceAndReadThroughTheEpisode() {
        #expect(EpisodeProvenance.proactiveLane == "proactive")
        #expect(episode(lane: EpisodeProvenance.proactiveLane).provenance.isProactive)
        #expect(!episode().provenance.isProactive)
    }
}
