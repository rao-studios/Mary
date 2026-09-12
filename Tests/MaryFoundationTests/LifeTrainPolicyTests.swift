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
        paradigm: AbilityParadigm = .discipline,
        at time: Date? = nil
    ) -> BehavioralEpisode {
        BehavioralEpisode(
            id: UUID(),
            openedAt: time ?? anchor,
            sealedAt: time ?? anchor,
            sealedReason: sealed,
            input: BehavioralInput(query: "type this"),
            provenance: EpisodeProvenance(engine: "local", lane: lane, appVersion: "test"),
            abilityTargets: [AbilityThreadTarget(abilityID: ability, paradigm: paradigm)])
    }

    // MARK: - The threshold

    @Test func theFirstAdapterNeedsTwentyFourTurns() {
        #expect(!LifeTrainPolicy.shouldTrain(completedCount: 23, newSinceTrain: nil))
        #expect(LifeTrainPolicy.shouldTrain(completedCount: 24, newSinceTrain: nil))
    }

    @Test func aRetrainNeedsTwelveNewTurnsSinceTheLastRun() {
        #expect(!LifeTrainPolicy.shouldTrain(completedCount: 400, newSinceTrain: 11))
        #expect(LifeTrainPolicy.shouldTrain(completedCount: 400, newSinceTrain: 12))
    }

    @Test func progressFillsTowardTheFirstAdapter() {
        let fill = LifeTrainPolicy.progress(completedCount: 12, newSinceTrain: nil)
        #expect(fill.filled == 12)
        #expect(fill.goal == 24)
        #expect(fill.fraction == 0.5)
    }

    @Test func progressAfterPublishCountsOnlyTheNewTurns() {
        let fill = LifeTrainPolicy.progress(completedCount: 30, newSinceTrain: 6)
        #expect(fill.filled == 6)
        #expect(fill.goal == 12)
    }

    /// Past its goal the bar holds full — the window rolls instead.
    @Test func progressNeverOverfillsItsBar() {
        #expect(LifeTrainPolicy.progress(completedCount: 400, newSinceTrain: 376).fraction == 1)
        #expect(LifeTrainPolicy.progress(completedCount: 400, newSinceTrain: nil).filled == 24)
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

    // MARK: - The window

    /// A RUN LEARNS FROM THE LATEST 24, oldest first. Each new turn pushes
    /// the oldest out.
    @Test func aRunLearnsFromTheLatestTwentyFourTurns() {
        let episodes = (0..<30).map { episode(at: anchor.addingTimeInterval(Double($0))) }
        let window = LifeTrainPolicy.window(episodes.shuffled(), abilityID: .writing)
        #expect(window.count == 24)
        #expect(window.first?.sealedAt == anchor.addingTimeInterval(6))
        #expect(window.last?.sealedAt == anchor.addingTimeInterval(29))
    }

    @Test func theWindowHoldsOnlyTurnsThatCanTeach() {
        let episodes = [
            episode(at: anchor),
            episode(lane: EpisodeProvenance.proactiveLane, at: anchor.addingTimeInterval(1)),
            episode(ability: .coding, at: anchor.addingTimeInterval(2)),
            episode(sealed: .cancelled, at: anchor.addingTimeInterval(3)),
        ]
        #expect(LifeTrainPolicy.window(episodes, abilityID: .writing).count == 1)
    }

    /// A run's pair count stays at the window, so new turns are counted by time.
    @Test func newTurnsAreCountedFromWhenTheLastRunTrained() {
        let episodes = [
            episode(at: anchor.addingTimeInterval(-10)),
            episode(at: anchor),
            episode(at: anchor.addingTimeInterval(10)),
            episode(at: anchor.addingTimeInterval(20)),
        ]
        #expect(LifeTrainPolicy.completedCount(
            in: episodes, abilityID: .writing, after: anchor) == 2)
    }
}
