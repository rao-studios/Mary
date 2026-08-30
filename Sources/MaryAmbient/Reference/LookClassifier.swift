//
//  LookClassifier.swift
//  MaryAmbient
//
//  IS THIS QUESTION ABOUT WHAT'S ON THE SCREEN? — the trigger for the
//  pre-lane look, `NamedPartClassifier`'s sibling with the INVERSE bias.
//
//  That classifier leans toward firing because a false positive costs
//  ~100-300ms of AppleScript. Here a false positive costs SECONDS of dead
//  air on an ordinary conversational turn (the voice holds for the look),
//  so this one is conservative: it demands BOTH a question shape and a
//  visual referent, and every veto is named after its failure class. The
//  structural bounds around the call site do the widening — the dispatcher
//  declines when a world with its own eyes leads, and a missed trigger
//  still gets the look through Lane B plus the spoken follow-up.
//
//  Deliberately SEPARATE from `AmbientRanker.isDeictic`: that list is
//  routing vocabulary whose own header forbids widening ("every turn would
//  be 'about the focused world'"), and its pins hold. "What building that
//  is" correctly stays `.converse` for routing; it is still a look
//  question, and this classifier is where that narrower fact lives.
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
        "hey", "mary", "bonnie", "ok", "okay", "oh", "so", "well", "um", "uh",
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
