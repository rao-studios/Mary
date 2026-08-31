//
//  EmbeddingRouting.swift
//  MaryBrain
//
//  WHAT: Floor, unique Skill pick, confidence-dispatch eligibility + arguments.
//  IN:   affinities + snapshot
//  OUT:  TurnLoop early dispatch
//  PIN:  No per-skill-name argument special-casing — SpokenArgumentExtractor
//        generalizes across any platform from the skill's OWN package data.
//

import MaryAmbient
import MaryFoundation
import MaryPlugin
import Foundation

public enum EmbeddingRouting {

    public static let floor: Float = 0.62
    public static let margin: Float = 0.04

    /// Exactly one Skill above the floor, with a margin over the runner-up.
    public static func uniqueWinner(
        affinities: [SkillID: Float],
        snapshot: AbilityRuntimeSnapshot,
        floor: Float = floor,
        margin: Float = margin
    ) -> AbilityRuntimeSkill? {
        let ranked = affinities
            .filter { $0.value >= floor }
            .compactMap { id, score -> (AbilityRuntimeSkill, Float)? in
                guard let skill = snapshot.skills.first(where: { $0.skill.id == id }),
                      skill.availability.readiness == .ready,
                      skill.skill.modelExposure.enabled
                else { return nil }
                return (skill, score)
            }
            .sorted { $0.1 > $1.1 }
        guard let first = ranked.first else { return nil }
        if let second = ranked.dropFirst().first, first.1 - second.1 < margin {
            return nil
        }
        return first.0
    }

    /// A skill the shortcut may safely build arguments for: exactly one
    /// required string parameter, no enum (that's structured data, not a
    /// spoken span), and not opted out via `requiresComposition` (a commit
    /// message, replacement prose, a computed value — content only a model
    /// round can produce). Anything else falls through to Lane B untouched,
    /// exactly as if `uniqueWinner` had returned nil.
    public static func isEligibleForArgumentExtraction(_ skill: AbilityRuntimeSkill) -> Bool {
        let required = skill.skill.modelExposure.parameters.filter(\.required)
        guard required.count == 1, let only = required.first else { return false }
        return only.type == "string" && only.enumValues.isEmpty && !only.requiresComposition
    }

    /// The skill's one required string parameter takes the utterance's
    /// extracted span, not the whole sentence — generalized via
    /// `SpokenArgumentExtractor` from the skill's OWN ability triggers and
    /// the resolved application's OWN aliases, never a per-skill-name list.
    public static func argumentsJSON(
        for skill: AbilityRuntimeSkill,
        utterance: String,
        applicationID: String?,
        applicationProfiles: [ApplicationProfile] = []
    ) -> String {
        var args: [String: String] = [:]
        let required = skill.skill.modelExposure.parameters.filter(\.required)
        if required.count == 1, let only = required.first, only.type == "string" {
            let aliases = applicationProfiles.first { $0.id == applicationID }?.aliases ?? []
            args[only.name] = SpokenArgumentExtractor.extract(
                utterance, triggers: skill.ability.triggers, applicationAliases: aliases)
        }
        if let applicationID, !applicationID.isEmpty,
           skill.skill.modelExposure.parameters.contains(where: { $0.name == "app" }) {
            args["app"] = applicationID
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    public static func recordExemplars(
        query: String,
        intent: AmbientIntent,
        outcomes: [(skillID: String, ok: Bool)],
        store: RoutingExemplarStore = .shared
    ) {
        guard !query.isEmpty else { return }
        for row in outcomes where !row.skillID.isEmpty {
            store.record(RoutingExemplar(
                query: query,
                skillID: row.skillID,
                intent: intent.rawValue,
                ok: row.ok))
        }
    }
}
