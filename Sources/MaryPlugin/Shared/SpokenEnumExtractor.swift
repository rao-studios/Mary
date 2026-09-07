//
//  SpokenEnumExtractor.swift
//  MaryPlugin
//
//  WHAT: Which declared enum value did the person actually say?
//  IN:   the raw utterance + the parameter's OWN enum values and spoken words
//  OUT:  EmbeddingRouting (the no-model lane) and the dispatch chokepoint
//  PIN:  ONE VALUE OR NONE, NEVER A GUESS. Two values in one sentence is a
//        sentence the model should read ("pause it and then skip to the next
//        one" is two acts); zero is nothing to say. The whole safety of
//        letting a structured argument skip the model rests on this refusing
//        far more often than it answers.
//        NO VERB LIST LIVES HERE. Every word this matches came out of the
//        package's own `enumValues` and `spokenValues` — see the PIN on
//        `ModelParameterSchema.spokenValues`. This file must stay ignorant of
//        music, browsers, and scrolling.
//

import Foundation
import MaryAmbient
import MaryFoundation

public enum SpokenEnumExtractor {

    /// One declared value, and the words that reached it.
    public struct Match: Sendable, Equatable {
        /// The enum value to send — always a member of `enumValues`.
        public var value: String
        /// What the person said that matched, for the trace.
        public var spokenAs: String

        public init(value: String, spokenAs: String) {
            self.value = value
            self.spokenAs = spokenAs
        }
    }

    /// The one enum value this utterance names, or nil.
    ///
    /// LONGEST PHRASE FIRST, so "turn it down" is not answered by whichever of
    /// its words some other value happens to claim; and a phrase that matched
    /// is REMOVED before the shorter candidates are tried, so "go back" does
    /// not also count as a bare "back" for a second value.
    public static func value(
        for parameter: ModelParameterSchema,
        in utterance: String
    ) -> Match? {
        guard !parameter.enumValues.isEmpty else { return nil }
        let text = " " + normalized(
            EditIntentClassifier.stripPreamble(utterance, applicationAliases: [])) + " "
        guard text.count > 2 else { return nil }

        // Every (phrase → value) this parameter admits: the value's own name
        // first, then whatever the package said people say for it.
        var candidates: [(phrase: String, value: String)] = []
        for value in parameter.enumValues {
            let spelled = normalized(value)
            if !spelled.isEmpty { candidates.append((spelled, value)) }
            for spoken in parameter.spokenValues[value] ?? [] {
                let phrase = normalized(spoken)
                guard !phrase.isEmpty, phrase != spelled else { continue }
                candidates.append((phrase, value))
            }
        }
        candidates.sort {
            $0.phrase.count == $1.phrase.count
                ? $0.phrase < $1.phrase
                : $0.phrase.count > $1.phrase.count
        }

        var remaining = text
        var hits: [Match] = []
        for candidate in candidates {
            let needle = " " + candidate.phrase + " "
            guard remaining.contains(needle) else { continue }
            // A value already reached by a longer phrase is the same answer,
            // not a rival: "turn it down" and "down" mean one thing.
            remaining = remaining.replacingOccurrences(of: needle, with: " ")
            guard !hits.contains(where: { $0.value == candidate.value }) else { continue }
            hits.append(Match(value: candidate.value, spokenAs: candidate.phrase))
        }
        // TWO IS A REFUSAL. See this file's PIN.
        guard hits.count == 1 else { return nil }
        return hits.first
    }

    /// The arguments a caller already has, with every enum parameter repaired
    /// from the words when the caller left it blank or sent something the enum
    /// does not contain.
    ///
    /// PIN: REPAIR, NEVER OVERRIDE. A value the caller sent that IS in the enum
    /// is what the caller meant, whatever the sentence also happens to contain
    /// — the model reads more of the turn than one utterance line does.
    public static func repaired(
        _ arguments: [String: String],
        parameters: [ModelParameterSchema],
        utterance: String
    ) -> [String: String] {
        guard !utterance.isEmpty else { return arguments }
        var repaired = arguments
        for parameter in parameters where !parameter.enumValues.isEmpty {
            let sent = repaired[parameter.name]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let alreadyValid = parameter.enumValues.contains {
                $0.caseInsensitiveCompare(sent) == .orderedSame
            }
            guard !alreadyValid else { continue }
            // NOTHING SAID, NOTHING ADDED — an optional enum nobody spoke stays
            // absent, and a required one the words do not name keeps failing in
            // the binding, where the refusal can say what it wanted.
            guard let match = value(for: parameter, in: utterance) else { continue }
            repaired[parameter.name] = match.value
        }
        return repaired
    }

    /// Lowercased, punctuation flattened to single spaces — the same shape both
    /// the haystack and every needle are put in, so a match is a word match.
    static func normalized(_ value: String) -> String {
        value.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { partial, character in
                if character == " ", partial.last == " " { return }
                partial.append(character)
            }
            .trimmingCharacters(in: .whitespaces)
    }
}
