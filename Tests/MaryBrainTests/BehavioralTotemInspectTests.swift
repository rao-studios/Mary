//
//  BehavioralTotemInspectTests.swift
//  MaryBrainTests
//
//  The Ability Totem body is the sealed BehavioralEpisode. Tags and the
//  Personal stub are a pure function of that episode so the pane and the
//  writer cannot drift.
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryBrain

@Suite struct BehavioralTotemInspectTests {

    private let coding = AbilityTotemTarget(abilityID: .coding, paradigm: .discipline)
    private let provenance = EpisodeProvenance(
        engine: "hosted", lane: "dual", appVersion: "test")
    private let prior = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    @Test func codecRoundTripPreservesAbilityTargetsAndTags() throws {
        var episode = sampleEpisode(didAct: true)
        episode.seal(.completed, at: Date(timeIntervalSince1970: 1_700_000_000))

        let line = try BehavioralCodec.line(episode)
        let decoded = try BehavioralCodec.episode(from: line)
        #expect(decoded.abilityTargets == [coding])
        #expect(decoded.input.query == "tidy the note")
        #expect(decoded.didAct)

        let json = String(data: line, encoding: .utf8) ?? ""
        let tags = BehavioralTotemInspect.abilityTags(episode: decoded, target: coding)
        #expect(tags.contains("schema:mary.behavior"))
        #expect(tags.contains("schema_version:1"))
        #expect(tags.contains("episode:\(episode.id.uuidString.lowercased())"))
        #expect(tags.contains("ability:coding"))
        #expect(tags.contains("paradigm:discipline"))
        #expect(tags.contains("sealed:completed"))
        #expect(tags.contains("did_act:true"))
        #expect(tags.contains("engine:hosted"))
        #expect(tags.contains("turn_lane:dual"))
        #expect(tags.contains("skill:write"))
        #expect(!tags.contains { $0.hasPrefix("projection-purpose:") })
        #expect(!json.contains("projection-purpose"))
        #expect(!json.contains("projection_purpose"))
    }

    @Test func personalStubJoinsTheAbilityDocumentOnTheSameEpisodeUUID() throws {
        var episode = sampleEpisode(didAct: false)
        episode.seal(.completed)
        let stub = try #require(
            BehavioralTotemInspect.interactionStub(from: episode, ownerID: "o"))
        #expect(stub.abilityDocumentID
                == TotemMemoryTopology.behaviorDocumentID(episodeID: episode.id))
        #expect(stub.episodeID == episode.id)
        #expect(stub.query == "tidy the note")
        #expect(stub.priorEpisodeID == prior)
        #expect(stub.didAct == false)
        #expect(stub.abilityGroupIDs == [
            TotemMemoryTopology.abilityGroup(target: coding, ownerID: "o").id
        ])

        let json = try BehavioralTotemInspect.stubJSON(stub)
        #expect(json.contains("\"ability_document_id\""))
        #expect(json.contains("\"episode_id\""))
        let parsed = try #require(BehavioralTotemInspect.interaction(from: json))
        #expect(parsed.abilityDocumentID == stub.abilityDocumentID)
    }

    @Test func emptyTargetsSkipThePersonalStub() {
        var episode = sampleEpisode(didAct: false, targets: [])
        episode.seal(.completed)
        #expect(BehavioralTotemInspect.interactionStub(from: episode, ownerID: "o") == nil)
    }

    @Test func paneDecoderRendersInputAndOutputSections() throws {
        var episode = sampleEpisode(didAct: true)
        episode.seal(.superseded)
        let body = try String(data: BehavioralCodec.line(episode), encoding: .utf8) ?? ""
        let view = try #require(BehavioralTotemInspect.codec(from: body))
        #expect(view.query == "tidy the note")
        #expect(view.priorEpisodeID == prior)
        #expect(view.ambientMode == "relevance")
        #expect(view.ambientLead == "Pages")
        #expect(view.didAct)
        #expect(view.sealedReason == "superseded")
        #expect(view.actions.map(\.intention) == ["write"])
        #expect(view.actions.map(\.disposition) == ["succeeded"])
        #expect(view.trainingTags.contains("did_act:true"))
        #expect(view.trainingTags.contains("sealed:superseded"))
        #expect(view.trainingTags.contains("ability:coding"))
        #expect(view.trainingTags.contains("episode:\(episode.id.uuidString.lowercased())"))
    }

    private func sampleEpisode(
        didAct: Bool,
        targets: [AbilityTotemTarget]? = nil
    ) -> BehavioralEpisode {
        let actions: [BehavioralActionRecord]
        if didAct {
            actions = [
                BehavioralActionRecord(
                    id: "run-1",
                    action: BehavioralAction(
                        intention: "write",
                        argumentsJSON: "{}",
                        skill: AbilitySkillReference(
                            packageID: PackageID(rawValue: "writing")!,
                            packageVersion: SemanticVersion("1.0.0"),
                            abilityID: .writing,
                            abilityTitle: "Writing",
                            abilityTint: "blue",
                            skillID: SkillID(rawValue: "write")!,
                            skillTitle: "Write",
                            invocationName: "write")),
                    disposition: .succeeded,
                    summary: "rewrote the paragraph",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            ]
        } else {
            actions = []
        }
        return BehavioralEpisode(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            openedAt: Date(timeIntervalSince1970: 1_700_000_000),
            input: BehavioralInput(
                query: "tidy the note",
                ambient: AmbientCapture(mode: "relevance", lead: "Pages"),
                priorEpisodeID: prior),
            output: BehavioralOutput(actions: actions),
            provenance: provenance,
            abilityTargets: targets ?? [coding])
    }
}
