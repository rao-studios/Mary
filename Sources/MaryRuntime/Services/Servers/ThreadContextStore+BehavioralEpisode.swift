//
//  ThreadContextStore+BehavioralEpisode.swift
//  MaryRuntime
//
//  WHAT: Sealed BehavioralEpisode is the Ability Thread record.
//  OUT:  Personal holds only the interaction stub, joined by turn UUID.
//

import MaryBrain
import MaryThread
import MaryFoundation
import MaryAmbient
import Foundation

struct ThreadBehavioralRecording: BehavioralRecording {
    func append(_ episode: BehavioralEpisode) async {
        let id = BehavioralAssembler.shortID(episode.id)
        let deposited = await MaryRuntime.threadContext.depositBehavioralEpisode(episode)
        if deposited {
            await MaryRuntime.refreshBehaviorEpisodesFromThread()
            let line = "handoff deposited \(id)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        } else {
            let line = "handoff dropped \(id)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        }
        MaryRuntime.noteSealedEpisode(episode)
    }
}

extension ThreadContextStore {

    @discardableResult
    func depositBehavioralEpisode(_ episode: BehavioralEpisode) async -> Bool {
        let id = BehavioralAssembler.shortID(episode.id)
        guard let owner = await session.userID else {
            let line = "deposit skipped \(id) — not signed in"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
            MaryRuntime.abilityDepositNoticeBox.withLock {
                $0 = "Sign in to Sewn first — Thread holds Ability turns per owner."
            }
            return false
        }
        guard !episode.abilityTargets.isEmpty else {
            let line = "deposit skipped \(id) — no ability targets"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
            return false
        }
        guard let body = try? String(
            data: BehavioralCodec.line(episode), encoding: .utf8)
        else {
            let line = "deposit skipped \(id) — encode failed"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
            return false
        }

        let documentID = ThreadMemoryTopology.behaviorDocumentID(episodeID: episode.id)
        var deposited = false
        for target in episode.abilityTargets {
            let group = ThreadMemoryTopology.abilityGroup(target: target, ownerID: owner)
            let item = DepositItem(
                documentID: documentID,
                texts: [body],
                tags: BehavioralThreadInspect.abilityTags(episode: episode, target: target),
                name: "Behavior · \(episode.input.query)",
                metadata: Self.behaviorMetadata(episode, target: target),
                entities: Self.behaviorEntities(episode),
                relationships: Self.behaviorRelationships(episode))
            do {
                _ = try await client.deposit(
                    [item], ownerID: owner,
                    groupID: group.id, groupLabel: group.label,
                    scope: ThreadLane.ability.rawValue)
                deposited = true
                MaryRuntime.abilityDepositNoticeBox.withLock { $0 = nil }
                let line = "deposited \(id) → \(target.abilityID.rawValue)/\(target.paradigm.rawValue)"
                BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
            } catch {
                let line = "deposit failed \(id) → \(target.abilityID.rawValue)/\(target.paradigm.rawValue) — \(error.localizedDescription)"
                BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
                MaryRuntime.abilityDepositNoticeBox.withLock {
                    $0 = "Couldn't deposit Ability turns: \(error.localizedDescription)"
                }
            }
        }

        guard let stub = BehavioralThreadInspect.interactionStub(
                from: episode, ownerID: owner),
              let stubJSON = try? BehavioralThreadInspect.stubJSON(stub)
        else {
            let line = "personal stub skipped \(id)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
            return deposited
        }
        let interactions = ThreadMemoryTopology.interactionGroup(ownerID: owner)
        let pointer = DepositItem(
            documentID: ThreadMemoryTopology.interactionDocumentID(episodeID: episode.id),
            texts: [stubJSON],
            tags: [
                "schema:mary.behavior.interaction",
                "episode:\(episode.id.uuidString.lowercased())",
                "thread:personal",
            ],
            name: episode.input.query,
            metadata: Self.interactionMetadata(stub),
            entities: [
                ThreadEntityIn(name: episode.id.uuidString.lowercased(), kind: "episode"),
            ],
            relationships: [])
        do {
            _ = try await client.deposit(
                [pointer], ownerID: owner,
                groupID: interactions.id, groupLabel: interactions.label,
                scope: ThreadLane.personal.rawValue)
            let line = "personal stub deposited \(id)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        } catch {
            let line = "personal stub failed \(id) — \(error.localizedDescription)"
            BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
        }
        return deposited
    }

    private static func behaviorMetadata(
        _ episode: BehavioralEpisode, target: AbilityThreadTarget
    ) -> Data {
        var fields: [String: String] = [
            "episode_id": episode.id.uuidString.lowercased(),
            "ability_id": target.abilityID.rawValue,
            "paradigm": target.paradigm.rawValue,
            "did_act": episode.didAct ? "true" : "false",
            "thread_lane": ThreadLane.ability.rawValue,
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
            "thread_lane": ThreadLane.personal.rawValue,
        ]
        if let prior = stub.priorEpisodeID {
            fields["prior_episode_id"] = prior.uuidString.lowercased()
        }
        return (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    private static func behaviorEntities(_ episode: BehavioralEpisode) -> [ThreadEntityIn] {
        var entities = [
            ThreadEntityIn(name: episode.id.uuidString.lowercased(), kind: "episode"),
        ]
        var names = Set(entities.map(\.name))
        for target in episode.abilityTargets {
            let name = target.abilityID.rawValue
            if names.insert(name).inserted {
                entities.append(ThreadEntityIn(name: name, kind: "ability"))
            }
        }
        for skill in Set(episode.output.actions.map(\.action.skill.skillID.rawValue)) {
            if names.insert(skill).inserted {
                entities.append(ThreadEntityIn(name: skill, kind: "skill"))
            }
        }
        return entities
    }

    private static func behaviorRelationships(
        _ episode: BehavioralEpisode
    ) -> [ThreadRelationIn] {
        let episodeName = episode.id.uuidString.lowercased()
        var relations: [ThreadRelationIn] = []
        for skill in Set(episode.output.actions.map(\.action.skill.skillID.rawValue)) {
            relations.append(ThreadRelationIn(
                subject: episodeName, predicate: "records", object: skill))
        }
        for target in episode.abilityTargets where target.paradigm == .discipline {
            relations.append(ThreadRelationIn(
                subject: episodeName,
                predicate: UnitRelationPredicate.practices.rawValue,
                object: target.abilityID.rawValue))
        }
        return relations
    }

    /// One sealed episode by the turn UUID Thread files it under.
    func episode(id: UUID) async -> BehavioralEpisode? {
        guard let owner = await session.userID else { return nil }
        let documentID = ThreadMemoryTopology.behaviorDocumentID(episodeID: id)
        guard let documents = try? await client.documents(ids: [documentID], ownerID: owner),
              let body = documents.first?.content
        else { return nil }
        return Self.decodeEpisode(body)
    }

    /// Every Ability-lane behavior document, paged. Nil means the owner is
    /// missing or Thread refused the export — leave the caller's cache alone.
    func exportBehaviorEpisodes(groupIDs: [String] = []) async -> [BehavioralEpisode]? {
        guard let owner = await session.userID else { return nil }
        var all: [BehavioralEpisode] = []
        var after = ""
        for _ in 0..<50 {
            let page: (documents: [DocumentContent], hasMore: Bool)
            do {
                page = try await client.exportCorpus(
                    ownerID: owner,
                    groupIDs: groupIDs,
                    documentIDPrefix: "mary-behavior-",
                    afterID: after,
                    limit: 200)
            } catch {
                let line = "export failed — \(error.localizedDescription)"
                BehavioralAssembler.behavioralLog.info("\(line, privacy: .public)")
                return nil
            }
            for document in page.documents {
                if let episode = Self.decodeEpisode(document.content) {
                    all.append(episode)
                }
            }
            guard page.hasMore, let last = page.documents.last else { break }
            after = last.id
        }
        return all
    }

    private static func decodeEpisode(_ body: String) -> BehavioralEpisode? {
        guard let data = body.data(using: .utf8) else { return nil }
        return try? BehavioralCodec.episode(from: data)
    }
}