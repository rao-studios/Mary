//
//  LifeTrainerWindowTests.swift
//  MaryRuntimeTests
//
//  WHAT: The pairs a run sends Fleet — a discipline's window, projected here.
//  OUT:  LifeTrainer.trainingPairs
//  PIN:  These must stay what Fleet's projector would make of the same turns:
//        acted rows first, none at all without one, no empty queries.
//

import Foundation
import Testing
import MaryBrain
import MaryFoundation
@testable import MaryRuntime

@Suite struct LifeTrainerWindowTests {

    private let anchor = Date(timeIntervalSince1970: 1_787_821_200)

    private func episode(query: String = "type this", acted: Bool) -> BehavioralEpisode {
        let actions: [BehavioralTrainingOutput.Action] = acted
            ? [.init(
                intention: "type_at_cursor",
                argumentsJSON: #"{"text":"hi"}"#,
                skillID: "writing.type-at-cursor",
                invocationName: "type_at_cursor",
                disposition: "succeeded",
                summary: "typed")]
            : []
        var episode = BehavioralTrainingOutput(actions: actions).makeEpisode(
            id: UUID(),
            input: BehavioralInput(query: query),
            provenance: EpisodeProvenance(engine: "local", lane: "dual", appVersion: "test"),
            abilityTargets: [AbilityThreadTarget(abilityID: .writing, paradigm: .discipline)],
            openedAt: anchor)
        episode.sealedAt = anchor
        episode.sealedReason = .completed
        return episode
    }

    @Test func actedTurnsComeFirstAndSilentOnesStay() {
        let pairs = LifeTrainer.trainingPairs([
            episode(acted: false), episode(acted: true), episode(acted: false),
        ])
        #expect(pairs.count == 3)
        #expect(pairs[0].outputJSON.contains("type_at_cursor"))
        #expect(!pairs[1].outputJSON.contains("type_at_cursor"))
    }

    /// Fleet draws the output schema from acted rows; a window with none
    /// has nothing to train on.
    @Test func aWindowWithNoActedTurnSendsNothing() {
        #expect(LifeTrainer.trainingPairs([episode(acted: false), episode(acted: false)]).isEmpty)
    }

    /// Fleet's projector drops a turn with no query; the window does too.
    @Test func aTurnWithNoQueryIsDropped() {
        let pairs = LifeTrainer.trainingPairs([episode(query: "", acted: true), episode(acted: true)])
        #expect(pairs.count == 1)
    }

    /// The input is the same projection Mary sends Fleet at inference.
    @Test func theInputIsMarysOwnProjection() throws {
        let one = episode(acted: true)
        let expected = String(
            data: try BehavioralTrainingPair(episode: one).encodedInput(), encoding: .utf8)
        #expect(LifeTrainer.trainingPairs([one]).first?.inputJSON == expected)
    }
}
