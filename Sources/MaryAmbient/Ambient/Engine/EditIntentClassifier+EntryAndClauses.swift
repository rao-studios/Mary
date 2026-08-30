//
//  EditIntentClassifier+EntryAndClauses.swift
//  MaryAmbient
//
//  WHAT: Entry point and clause helpers for revision detection.
//  IN:   EditIntentClassifier.swift (split)
//  OUT:  EditIntent / AmbientEngine
//

import Foundation

extension EditIntentClassifier {

    // MARK: - Entry point

    /// The revision the utterance asks for, or nil when it asks for none. Nil is the common and
    /// correct answer.
    public static func intent(
        in utterance: String,
        applicationAliases: Set<String> = []
    ) -> EditIntent? {
        // CLAUSE BY CLAUSE, and the whole utterance is simply the first clause tried. THE ANCHOR
        // IS KEPT, JUST SCOPED SMALLER.
        for clause in clauses(of: utterance) {
            // A question mark normally means the user wants an answer, not a mutation.
            if clause.contains("?"),
               !beginsWithPoliteRequestFrame(clause, applicationAliases: applicationAliases) {
                continue
            }
            if let intent = intentInClause(clause, applicationAliases: applicationAliases) {
                return intent
            }
        }
        return nil
    }

    private static func beginsWithPoliteRequestFrame(
        _ utterance: String,
        applicationAliases: Set<String> = []
    ) -> Bool {
        var words = utterance.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
        // At most ONE leading application alias reads as an address — the
        // same rule `ActionClassifier` applies, for the same live failure
        // ("Sketch can you add…" never reached its frame).
        var peeledAlias = false
        while let first = words.first,
              addressWords.contains(first) || backchannelWords.contains(first)
                  || (!peeledAlias && applicationAliases.contains(first)) {
            if applicationAliases.contains(first),
               !addressWords.contains(first), !backchannelWords.contains(first) {
                peeledAlias = true
            }
            words.removeFirst()
        }
        guard words.count >= 2 else { return false }
        return requestFrames.contains(Array(words.prefix(2)))
    }

    /// One clause's worth of the ladder — the whole of what `intent(in:)` used
    /// to do to the whole utterance.
    private static func intentInClause(
        _ utterance: String,
        applicationAliases: Set<String> = []
    ) -> EditIntent? {
        let text = stripPreamble(utterance, applicationAliases: applicationAliases)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard let first = words.first else { return nil }

        // Openers that want an ANSWER, borrowed whole from `ActionClassifier`.
        if ActionClassifier.questionOpeners.contains(first) { return nil }

        // The me/us veto, lifted from `ActionClassifier` for the same reason it exists there:
        // "update me on the build" opens with a revision verb and is not a revision.
        if words.count >= 2, words[1] == "me" || words[1] == "us" { return nil }

        // THE EYELESS VETO, WHOLE-INTENT. "delete the milk reminder" and "remove the three o'clock
        // event from my calendar" open with delete verbs and name things that live in EventKit,
        // not in a document.
        if NamedPartClassifier.namesAmbientSource(text) { return nil }

        // Four shapes, in order. Order matters only where verb sets could
        // overlap, and they are disjoint by construction — but a fixed order
        // means the table below is the whole specification.
        return replaceIntent(text)
            ?? deleteIntent(text)
            ?? insertIntent(text)
            ?? moveIntent(text)
    }

    // MARK: - Clauses

    /// Where a spoken sentence changes direction.
    public static let clauseBreaks: [String] = [
        ", ", " and then ", " and ", " so can you ", " can you ",
    ]

    /// The utterance, then each clause AROUND a break.
    public static func clauses(of utterance: String) -> [String] {
        let found = [utterance]
        var heads: [String] = []
        var tails: [String] = []
        // A one-word clause is a fragment, never an instruction; a clause
        // already collected is a repeat, not a new reading.
        func qualifies(_ clause: String) -> Bool {
            clause.split(whereSeparator: \.isWhitespace).count >= 2
                && !found.contains(clause)
                && !heads.contains(clause)
                && !tails.contains(clause)
        }
        let lowered = utterance.lowercased()
        for der in clauseBreaks {
            var searchFrom = lowered.startIndex
            while let range = lowered.range(
                of: der, range: searchFrom..<lowered.endIndex) {
                let head = String(utterance[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if qualifies(head) { heads.append(head) }
                let tail = String(utterance[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if qualifies(tail) { tails.append(tail) }
                searchFrom = range.upperBound
            }
        }
        return found + heads + tails
    }

}
