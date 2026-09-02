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

    /// What the shortcut would have to supply for this Skill.
    public enum ConfidenceArgumentShape: Sendable, Equatable {
        /// NOTHING TO GET WRONG. "Bring all my windows forward" carries no
        /// span at all — the verb IS the whole request.
        case noRequiredArguments
        /// One spoken span, extracted from the utterance.
        case singleString
    }

    /// The shape a shortcut may safely dispatch, or nil for "hand it to Lane B
    /// untouched", exactly as if `uniqueWinner` had returned nil.
    ///
    /// Two shapes qualify. A Skill needing NO required argument is the safest
    /// case there is — there is no span to mis-extract — and it was excluded
    /// only because the rule was written when every shortcut carried a title.
    /// A Skill needing exactly one plain string still qualifies: no enum
    /// (that is structured data, not a spoken span) and not opted out via
    /// `requiresComposition` (a commit message, replacement prose, a computed
    /// value — content only a model round can produce).
    public static func confidenceShape(
        of skill: AbilityRuntimeSkill
    ) -> ConfidenceArgumentShape? {
        let required = skill.skill.modelExposure.parameters.filter(\.required)
        if required.isEmpty { return .noRequiredArguments }
        guard required.count == 1, let only = required.first,
              only.type == "string", only.enumValues.isEmpty,
              !only.requiresComposition
        else { return nil }
        return .singleString
    }

    /// A ZERO-ARGUMENT VERB IS A WHOLE-SENTENCE CLAIM, so it must be a whole
    /// simple sentence. Lifted intact from the deleted window-verb gate, where
    /// it was proven: a compound request ("bring them forward and close the
    /// last one") is two acts, and dispatching the first without the model
    /// silently drops the second.
    ///
    /// FUNCTION-WORD SHAPE, NOT VOCABULARY — it tests joiners and punctuation,
    /// never what the sentence is about.
    public static func isSingleClause(_ utterance: String) -> Bool {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let words = trimmed.split { $0.isWhitespace }.map(String.init)
        guard words.count <= 12 else { return false }
        guard !trimmed.contains(";"), !trimmed.contains(","),
              !trimmed.contains("?")
        else { return false }
        let padded = " " + words.joined(separator: " ").lowercased() + " "
        let joiners = [" and ", " then ", " also ", " after that ", " plus "]
        return !joiners.contains { padded.contains($0) }
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
