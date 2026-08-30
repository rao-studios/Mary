//
//  TotemContextStore+BehavioralEpisode.swift
//
//  The sealed BehavioralEpisode IS the Ability Totem record. Personal holds
//  only the interaction stub that led to it, joined by the turn UUID.
//

import MaryBrain
import MaryTotem
import MaryFoundation
import MaryAmbient
import Foundation
import os

struct TotemBehavioralRecording: BehavioralRecording {
    func append(_ episode: BehavioralEpisode) async {
        await MaryRuntime.totemContext.depositBehavioralEpisode(episode)
    }
}

extension TotemContextStore {

    private static let log = Logger(subsystem: "nyc.rao.mary", category: "totem-behavior")

    func depositBehavioralEpisode(_ episode: BehavioralEpisode) async {
        guard let owner = await session.userID else {
            Self.log.debug("Ability Totem skipped: not signed in")
            MaryRuntime.abilityDepositNoticeBox.withLock {
                $0 = "Sign in to Seer first — Totem holds Ability turns per owner."
            }
            return
        }
        guard !episode.abilityTargets.isEmpty else { return }
        guard let body = try? String(
            data: BehavioralCodec.line(episode), encoding: .utf8)
        else {
            Self.log.error("Ability Totem skipped: episode would not encode")
            return
        }

        let documentID = TotemMemoryTopology.behaviorDocumentID(episodeID: episode.id)
        for target in episode.abilityTargets {
            let group = TotemMemoryTopology.abilityGroup(target: target, ownerID: owner)
            let item = DepositItem(
                documentID: documentID,
                texts: [body],
                tags: BehavioralTotemInspect.abilityTags(episode: episode, target: target),
                name: "Behavior · \(episode.input.query)",
                metadata: Self.behaviorMetadata(episode, target: target),
                entities: Self.behaviorEntities(episode),
                relationships: Self.behaviorRelationships(episode))
            do {
                _ = try await client.deposit(
                    [item], ownerID: owner,
                    groupID: group.id, groupLabel: group.label,
                    scope: TotemLane.ability.rawValue)
                MaryRuntime.abilityDepositNoticeBox.withLock { $0 = nil }
            } catch {
                Self.log.error(
                    "Ability Totem deposit failed: \(error.localizedDescription, privacy: .public)")
                MaryRuntime.abilityDepositNoticeBox.withLock {
                    $0 = "Couldn't deposit Ability turns: \(error.localizedDescription)"
                }
            }
        }

        guard let stub = BehavioralTotemInspect.interactionStub(
                from: episode, ownerID: owner),
              let stubJSON = try? BehavioralTotemInspect.stubJSON(stub)
        else {
            Self.log.error("Personal interaction stub skipped — Ability deposit still ran")
            return
        }
        let interactions = TotemMemoryTopology.interactionGroup(ownerID: owner)
        let pointer = DepositItem(
            documentID: TotemMemoryTopology.interactionDocumentID(episodeID: episode.id),
            texts: [stubJSON],
            tags: [
                "schema:mary.behavior.interaction",
                "episode:\(episode.id.uuidString.lowercased())",
                "totem:personal",
            ],
            name: episode.input.query,
            metadata: Self.interactionMetadata(stub),
            entities: [
                TotemEntityIn(name: episode.id.uuidString.lowercased(), kind: "episode"),
            ],
            relationships: [])
        do {
            _ = try await client.deposit(
                [pointer], ownerID: owner,
                groupID: interactions.id, groupLabel: interactions.label,
                scope: TotemLane.personal.rawValue)
        } catch {
            Self.log.error(
                "Personal interaction deposit failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func behaviorMetadata(
        _ episode: BehavioralEpisode, target: AbilityTotemTarget
    ) -> Data {
        var fields: [String: String] = [
            "episode_id": episode.id.uuidString.lowercased(),
            "ability_id": target.abilityID.rawValue,
            "paradigm": target.paradigm.rawValue,
            "did_act": episode.didAct ? "true" : "false",
            "totem_lane": TotemLane.ability.rawValue,
        ]
        if let prior = episode.input.priorEpisodeID {
            fields["prior_episode_id"] = prior.uuidString.lowercased()
        }
        if let sealed = episode.sealedAt {
            fields["sealed_at"] = ISO8601DateFormatter().string(from: sealed)
        }
        if let reason = episode.sealedReason {
            fields["sealed_reason"] = reason.rawValue
        }
        return (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    private static func interactionMetadata(_ stub: BehavioralInteractionStub) -> Data {
        var fields: [String: String] = [
            "episode_id": stub.episodeID.uuidString.lowercased(),
            "ability_document_id": stub.abilityDocumentID,
            "did_act": stub.didAct ? "true" : "false",
            "totem_lane": TotemLane.personal.rawValue,
        ]
        if let prior = stub.priorEpisodeID {
            fields["prior_episode_id"] = prior.uuidString.lowercased()
        }
        return (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    private static func behaviorEntities(_ episode: BehavioralEpisode) -> [TotemEntityIn] {
        var entities = [
            TotemEntityIn(name: episode.id.uuidString.lowercased(), kind: "episode"),
        ]
        var names = Set(entities.map(\.name))
        for target in episode.abilityTargets {
            let name = target.abilityID.rawValue
            if names.insert(name).inserted {
                entities.append(TotemEntityIn(name: name, kind: "ability"))
            }
        }
        for skill in Set(episode.output.actions.map(\.action.skill.skillID.rawValue)) {
            if names.insert(skill).inserted {
                entities.append(TotemEntityIn(name: skill, kind: "skill"))
            }
        }
        return entities
    }

    private static func behaviorRelationships(
        _ episode: BehavioralEpisode
    ) -> [TotemRelationIn] {
        let episodeName = episode.id.uuidString.lowercased()
        var relations: [TotemRelationIn] = []
        for skill in Set(episode.output.actions.map(\.action.skill.skillID.rawValue)) {
            relations.append(TotemRelationIn(
                subject: episodeName, predicate: "records", object: skill))
        }
        for target in episode.abilityTargets where target.paradigm == .discipline {
            relations.append(TotemRelationIn(
                subject: episodeName,
                predicate: UnitRelationPredicate.practices.rawValue,
                object: target.abilityID.rawValue))
        }
        return relations
    }
}