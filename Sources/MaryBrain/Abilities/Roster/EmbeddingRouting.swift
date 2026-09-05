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
        snapshot: AbilityRuntime.Snapshot,
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
        /// ONE STRUCTURED VALUE THE PERSON ACTUALLY NAMED. An enum was excluded
        /// wholesale because "structured data is not a spoken span" — true of the
        /// span, wrong about the value: "pause" IS the enum member, said out loud.
        /// The exclusion is what made every "pause the music" cost a model round,
        /// and a small model with two near-identical transport skills in front of
        /// it is exactly where that round goes wrong. Admitted only when the
        /// utterance names EXACTLY ONE of the declared values (see
        /// `SpokenEnumExtractor`); two, or none, still fall to the model.
        case singleEnum
    }

    /// The shape a shortcut may safely dispatch, or nil for "hand it to Lane B
    /// untouched", exactly as if `uniqueWinner` had returned nil.
    ///
    /// Two shapes qualify. A Skill needing NO required argument is the safest
    /// case there is — there is no span to mis-extract — and it was excluded
    /// only because the rule was written when every shortcut carried a title.
    /// A Skill needing exactly one plain string still qualifies, as long as it
    /// is not opted out via `requiresComposition` (a commit message, replacement
    /// prose, a computed value — content only a model round can produce).
    /// AND ONE ENUM QUALIFIES TOO, when the sentence names exactly one of its
    /// declared values. This comment used to say an enum was excluded because
    /// "structured data is not a spoken span"; that was true of the SPAN and
    /// wrong about the VALUE — "pause" IS the member, said out loud. See
    /// `.singleEnum` and `SpokenEnumExtractor`.
    public static func confidenceShape(
        of skill: AbilityRuntimeSkill,
        utterance: String = ""
    ) -> ConfidenceArgumentShape? {
        let required = skill.skill.modelExposure.parameters.filter(\.required)
        if required.isEmpty { return .noRequiredArguments }
        guard required.count == 1, let only = required.first,
              only.type == "string", !only.requiresComposition
        else { return nil }
        if !only.enumValues.isEmpty {
            // THE VALUE HAS TO BE IN THE SENTENCE. Without an utterance to read
            // there is nothing to fill this from, so the shape does not qualify —
            // which keeps every existing caller that asks shape-only honest.
            guard SpokenEnumExtractor.value(for: only, in: utterance) != nil else {
                return nil
            }
            return .singleEnum
        }
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
        var trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        // A TRAILING QUESTION MARK ENDS A SENTENCE; IT DOES NOT JOIN TWO. The
        // rule below refuses "?" because a question is usually not a command —
        // but dictation punctuates, and "Can you go back?" is one clause and one
        // act. Only the last character is forgiven: a "?" mid-sentence really is
        // two utterances run together.
        if trimmed.hasSuffix("?") {
            trimmed = String(trimmed.dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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
        filledArguments(
            for: skill, utterance: utterance, applicationID: applicationID,
            applicationProfiles: applicationProfiles).json
    }

    /// The shortcut's arguments, and how the words became them.
    ///
    /// `stages` is what the peeling actually did, in order — the only evidence a
    /// no-model dispatch produced the right argument, and previously visible
    /// nowhere at all.
    public static func filledArguments(
        for skill: AbilityRuntimeSkill,
        utterance: String,
        applicationID: String?,
        applicationProfiles: [ApplicationProfile] = []
    ) -> (json: String, stages: [String]) {
        var args: [String: String] = [:]
        var stages: [String] = []
        let parameters = skill.skill.modelExposure.parameters
        let required = parameters.filter(\.required)
        if required.count == 1, let only = required.first, only.type == "string" {
            if only.enumValues.isEmpty {
                let aliases = applicationProfiles.first { $0.id == applicationID }?.aliases ?? []
                let peeled = SpokenArgumentExtractor.peeled(
                    utterance, triggers: skill.ability.triggers, applicationAliases: aliases)
                args[only.name] = peeled.value
                stages += peeled.stages
            } else if let match = SpokenEnumExtractor.value(for: only, in: utterance) {
                args[only.name] = match.value
                stages.append("enum \(only.name): \"\(match.spokenAs)\" -> \(match.value)")
            }
        }
        // AN OPTIONAL ENUM THE PERSON NAMED IS STILL A THING THEY SAID. "Scroll
        // up" won `scroll_page` on the corpus, then dispatched with no arguments
        // at all — and the binding's own default scrolled DOWN. A skill needing
        // no required argument may still carry an optional one the sentence
        // fills, and leaving it out is not neutrality, it is the wrong answer.
        for parameter in parameters
        where !parameter.required && !parameter.enumValues.isEmpty
            && args[parameter.name] == nil {
            guard let match = SpokenEnumExtractor.value(for: parameter, in: utterance)
            else { continue }
            args[parameter.name] = match.value
            stages.append("enum \(parameter.name): \"\(match.spokenAs)\" -> \(match.value)")
        }
        if let applicationID, !applicationID.isEmpty,
           parameters.contains(where: { $0.name == "app" }) {
            args["app"] = applicationID
        }
        let data = (try? JSONSerialization.data(
            withJSONObject: args, options: [.sortedKeys])) ?? Data("{}".utf8)
        return (String(data: data, encoding: .utf8) ?? "{}", stages)
    }

    public static func recordRoutingHabits(
        query: String,
        intent: AmbientIntent,
        outcomes: [(skillID: String, ok: Bool)],
        store: RoutingHabitStore = .shared
    ) {
        guard !query.isEmpty else { return }
        for row in outcomes where !row.skillID.isEmpty {
            store.record(RoutingHabit(
                query: query,
                skillID: row.skillID,
                intent: intent.rawValue,
                ok: row.ok))
        }
    }
}
