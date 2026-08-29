//
//  BehavioralTrainingPairTests.swift
//  MaryFoundationTests
//
//  Fleet's schema automaton needs identical keys on every output. These
//  tests pin that the pair always emits the frozen spine, that a missing
//  key fails decode, and that a gated output re-encodes as an episode.
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct BehavioralTrainingPairTests {

    @Test func everyKeyIsAlwaysPresentEvenWhenAmbientIsAbsent() throws {
        var episode = BehaviorFixtures.typedIntoTextEdit
        episode.input.ambient = nil
        episode.input.priorEpisodeID = nil
        let pair = BehavioralTrainingPair(episode: episode)
        let object = try jsonObject(pair.encodedInput())
        #expect(Set(object.keys) == [
            "query", "prior_episode_id", "ambient_mode", "ambient_lead",
            "fact_count", "ambient_summary",
        ])
        #expect(object["prior_episode_id"] as? String == "")
        #expect(object["ambient_mode"] as? String == "")
        #expect(intValue(object["fact_count"]) == 0)
    }

    @Test func actedAndSilentOutputsShareTheSameActionKeys() throws {
        let acted = BehavioralTrainingPair(episode: BehaviorFixtures.typedIntoTextEdit)
        var silent = BehaviorFixtures.typedIntoTextEdit
        silent.output.actions = []
        let quiet = BehavioralTrainingPair(episode: silent)

        let actedObject = try jsonObject(acted.encodedOutput())
        let quietObject = try jsonObject(quiet.encodedOutput())
        #expect(Set(actedObject.keys) == ["actions"])
        #expect(Set(quietObject.keys) == ["actions"])

        let actedActions = try #require(actedObject["actions"] as? [[String: Any]])
        #expect(actedActions.count == 1)
        #expect(Set(actedActions[0].keys) == [
            "intention", "arguments_json", "skill_id",
            "invocation_name", "disposition", "summary",
        ])
        let quietActions = try #require(quietObject["actions"] as? [[String: Any]])
        #expect(quietActions.isEmpty)
    }

    @Test func aMissingKeyFailsDecode() throws {
        let json = Data(#"{"query":"hi"}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try BehavioralCodec.decoder().decode(
                BehavioralTrainingInput.self, from: json)
        }
        let output = Data(#"{}"#.utf8)
        #expect(throws: DecodingError.self) {
            _ = try BehavioralCodec.decoder().decode(
                BehavioralTrainingOutput.self, from: output)
        }
    }

    @Test func aPredictedOutputReencodesAsAnEpisode() throws {
        let original = BehaviorFixtures.typedIntoTextEdit
        let pair = BehavioralTrainingPair(episode: original)
        let rebuilt = pair.output.makeEpisode(
            id: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!,
            input: pair.input.makeInput(),
            provenance: EpisodeProvenance(
                engine: "local", lane: "proactive", appVersion: "test"),
            abilityTargets: [
                AbilityTotemTarget(abilityID: .writing, paradigm: .discipline)
            ],
            openedAt: original.openedAt)
        #expect(rebuilt.input.query == original.input.query)
        #expect(rebuilt.output.actions.count == 1)
        #expect(rebuilt.output.actions[0].action.intention == "type_at_cursor")
        #expect(rebuilt.output.actions[0].action.skill.invocationName == "type_at_cursor")
        #expect(rebuilt.output.actions[0].action.target == nil)
        #expect(rebuilt.provenance.lane == "proactive")
        #expect(rebuilt.abilityTargets.first?.abilityID == .writing)
        let line = try BehavioralCodec.line(rebuilt)
        let roundTrip = try BehavioralCodec.episode(from: line)
        #expect(roundTrip.output.actions.map(\.action.intention)
                == rebuilt.output.actions.map(\.action.intention))
    }

    @Test func twoEpisodesWithDifferentActionCountsShareOutputKeys() throws {
        let one = BehavioralTrainingPair(episode: BehaviorFixtures.typedIntoTextEdit)
        var two = BehaviorFixtures.typedIntoTextEdit
        two.output.actions.append(BehaviorFixtures.typedRecord)
        let doubled = BehavioralTrainingPair(episode: two)
        let keys: (BehavioralTrainingPair) throws -> Set<String> = { pair in
            let object = try jsonObject(pair.encodedOutput())
            let actions = try #require(object["actions"] as? [[String: Any]])
            return Set(actions[0].keys)
        }
        #expect(try keys(one) == keys(doubled))
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data)
        return try #require(object as? [String: Any])
    }

    private func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? NSNumber { return value.intValue }
        return nil
    }
}
