//
//  LookClassifier.swift
//  MaryAmbient
//
//  WHAT: Is this question about what's on the screen? Trigger for the pre-lane look.
//  OUT:  lookQuery → dispatcher. Sibling: NamedPartClassifier (inverse bias).
//  PIN:  Conservative — false positive costs seconds of dead air. Separate from
//        AmbientRanker.isDeictic (routing vocabulary; do not widen that list).
//
import Foundation

public enum LookClassifier {

    /// Wh/aux openers a look question leads with. By construction the
    /// non-action population: `ActionClassifier.questionOpeners` vetoes
    /// action classification for these same words.
    static let questionOpeners: Set<String> = [
        "what", "whats", "who", "whos", "which", "where", "wheres",
        "can", "could", "do", "does", "is", "are", "tell", "describe",
        "show", "how",
    ]

    /// Words that point the question AT THE SCREEN. Token-bounded matches.
    static let sightWords: Set<String> = [
        "see", "look", "looking", "watching", "screen",
        "video", "picture", "image", "photo", "chart", "diagram", "graph",
    ]

    /// Deictic/demonstrative tokens — "what building THAT is", "what are
    /// THOSE". `isDeictic` covers "this"-shapes; these cover the rest,
    /// locally, without touching the routing list.
    static let demonstratives: Set<String> = ["this", "that", "these", "those"]

    /// Leading noise peeled before the opener check — the same words
    /// `ActionClassifier`/`EditIntentClassifier` peel, respelled minimally
    /// here to keep this classifier dependency-light and pure.
    static let leadingNoise: Set<String> = [
        "hey", "mary", "ok", "okay", "oh", "so", "well", "um", "uh",
        "yeah", "now", "also", "and", "but", "wait",
    ]

    /// The look's query, or nil when this is not a screen question.
    public static func lookQuery(in utterance: String) -> String? {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Calendar/reminders/mail/music questions never need eyes.
        guard !NamedPartClassifier.namesAmbientSource(trimmed) else { return nil }

        var tokens = trimmed.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        while let first = tokens.first, leadingNoise.contains(first) {
            tokens.removeFirst()
        }
        guard let opener = tokens.first else { return nil }

        // QUESTION-SHAPED: the opener must LEAD (this is what keeps "I think
        // that…" from ever firing), or the utterance ends in a question mark.
        let questionShaped = questionOpeners.contains(opener)
            || trimmed.hasSuffix("?")
        guard questionShaped else { return nil }

        // VISUAL REFERENT: deixis (routing's own list), a demonstrative, or
        // a sight/media word.
        let words = Set(tokens)
        let visual = AmbientRanker.isDeictic(trimmed)
            || !words.isDisjoint(with: demonstratives)
            || !words.isDisjoint(with: sightWords)
        guard visual else { return nil }

        return trimmed
    }
}
