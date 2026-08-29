//
//  BehavioralTotemInspect.swift
//  MaryBrain
//
//  PURE SHAPE OF A TOTEM BEHAVIORAL DEPOSIT — tags, the Personal stub, and
//  the pane's decoded codec. The writer in TotemContextStore must call these
//  so a test can pin the bytes without a server.
//

import Foundation
import MaryFoundation

public enum BehavioralTotemInspect {

    public static func abilityTags(
        episode: BehavioralEpisode, target: AbilityTotemTarget
    ) -> [String] {
        var tags = [
            "schema:mary.behavior",
            "schema_version:\(episode.schemaVersion)",
            "episode:\(episode.id.uuidString.lowercased())",
            "ability:\(target.abilityID.rawValue)",
            "paradigm:\(target.paradigm.rawValue)",
            "sealed:\(episode.sealedReason?.rawValue ?? "unsealed")",
            "did_act:\(episode.didAct ? "true" : "false")",
            "engine:\(episode.provenance.engine)",
            "turn_lane:\(episode.provenance.lane)",
            "totem:ability",
        ]
        for skill in Set(episode.output.actions.map(\.action.skill.skillID.rawValue)).sorted() {
            tags.append("skill:\(skill)")
        }
        return tags
    }

    public static func interactionStub(
        from episode: BehavioralEpisode, ownerID: String
    ) -> BehavioralInteractionStub? {
        guard !episode.abilityTargets.isEmpty else { return nil }
        return BehavioralInteractionStub(
            episodeID: episode.id,
            query: episode.input.query,
            priorEpisodeID: episode.input.priorEpisodeID,
            abilityDocumentID: TotemMemoryTopology.behaviorDocumentID(episodeID: episode.id),
            abilityGroupIDs: episode.abilityTargets.map {
                TotemMemoryTopology.abilityGroup(target: $0, ownerID: ownerID).id
            },
            sealedReason: episode.sealedReason?.rawValue,
            didAct: episode.didAct)
    }

    public static func stubJSON(_ stub: BehavioralInteractionStub) throws -> String {
        let data = try BehavioralCodec.encoder().encode(stub)
        return String(data: data, encoding: .utf8) ?? ""
    }

    public static func codec(from body: String) -> BehavioralCodecView? {
        guard let data = body.data(using: .utf8),
              let episode = try? BehavioralCodec.episode(from: data)
        else { return nil }
        return BehavioralCodecView(episode: episode)
    }

    public static func interaction(from body: String) -> BehavioralInteractionStub? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? BehavioralCodec.decoder().decode(
            BehavioralInteractionStub.self, from: data)
    }

    /// Deduped Ability tags across every stamped target — what the pane
    /// shows as training filters.
    public static func trainingTags(episode: BehavioralEpisode) -> [String] {
        var seen = Set<String>()
        var tags: [String] = []
        for target in episode.abilityTargets {
            for tag in abilityTags(episode: episode, target: target) {
                if seen.insert(tag).inserted { tags.append(tag) }
            }
        }
        return tags
    }
}

public struct BehavioralCodecView: Equatable, Sendable {
    public var query: String
    public var priorEpisodeID: UUID?
    public var ambientMode: String?
    public var ambientLead: String?
    public var factCount: Int
    public var sealedReason: String?
    public var didAct: Bool
    public var trainingTags: [String]
    public var actions: [Action]

    public struct Action: Equatable, Sendable {
        public var intention: String
        public var disposition: String
        public var summary: String
        public var skillID: String
    }

    public init(episode: BehavioralEpisode) {
        query = episode.input.query
        priorEpisodeID = episode.input.priorEpisodeID
        ambientMode = episode.input.ambient?.mode
        ambientLead = episode.input.ambient?.lead
        factCount = episode.input.ambient?.facts.count ?? 0
        sealedReason = episode.sealedReason?.rawValue
        didAct = episode.didAct
        trainingTags = BehavioralTotemInspect.trainingTags(episode: episode)
        actions = episode.output.actions.map {
            Action(
                intention: $0.action.intention,
                disposition: $0.disposition.rawValue,
                summary: $0.summary,
                skillID: $0.action.skill.skillID.rawValue)
        }
    }
}
