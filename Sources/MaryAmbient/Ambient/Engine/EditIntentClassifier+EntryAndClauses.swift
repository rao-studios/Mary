//
//  EditIntentClassifier+EntryAndClauses.swift
//  MaryAmbient
//
//  Split out of EditIntentClassifier.swift (docs/DECOMPOSITION.md
//  Wave 4) — pure relocation, no declaration changed.
//

import Foundation

extension EditIntentClassifier {

    // MARK: - Entry point

    /// The revision the utterance asks for, or nil when it asks for none.
    ///
    /// Nil is the common and correct answer. It means "this turn is not a
    /// revision" — a question, a piece of live composition, or an action in a
    /// world that has no document at all — and every caller must treat it as
    /// "carry on exactly as before", never as "no target found, improvise".
    public static func intent(
        in utterance: String,
        applicationAliases: Set<String> = []
    ) -> EditIntent? {
        // CLAUSE BY CLAUSE, and the whole utterance is simply the first clause
        // tried.
        //
        // THE FAILURE THIS FIXES (live, from the Routes pane): "To see the
        // implementation section here that starts with I built a minimum
        // viable product can you revise that section for me" classified as
        // `perceive via deixis` and never revised anything. Every shape is
        // `^`-anchored — a revision verb must LEAD — and `stripPreamble` peels
        // only four closed vocabularies from the front, so "To" stopped it at
        // index 0 and `revise`, at index 17, was structurally invisible. With
        // no intent the whole G1–G4 spine went dark: no locate, no passage in
        // the Skill execution lane's prompt, an INERT caret-write veto, and no report.
        //
        // THE ANCHOR IS KEPT, JUST SCOPED SMALLER. Everything it protects is
        // clause-local, so nothing is given up by asking per clause:
        //   "what did you replace"     — its only clause opens on a question
        //                                opener, still vetoed
        //   "write a paragraph about the budget" — no anchor clause, still nil
        //   "can we tighten the intro" — not the two-word frame, still nil
        // Each clause is peeled and vetoed independently, so a clause can only
        // produce an intent if it would have produced one standing alone.
        //
        // And the cost of being wrong has already changed, which this file's
        // own tests record: locate-first runs before any write and the caret
        // veto only fires on a located passage, so a spurious intent buys a
        // `find` that misses and a turn that carries on exactly as it would
        // have. It cannot overwrite anything.
        for clause in clauses(of: utterance) {
            // A question mark normally means the user wants an answer, not a
            // mutation. The closed polite-request frames are the deliberate
            // exception: “Can you reword that?” is ordinary imperative speech,
            // while “Should I reword that?” and “What did you reword?” remain
            // questions. Keeping the exception lexical avoids turning an
            // arbitrary revision verb elsewhere in a question into authority.
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

        // Openers that want an ANSWER, borrowed whole from `ActionClassifier`
        // — "what did you replace" and "how should I tighten the intro" are
        // requests for a reply, and a classifier that read either as an edit
        // would overwrite the intro while she was still deciding whether to.
        //
        // IT USED TO VETO "can you tighten the intro" TOO, and that row has
        // been re-decided — see `requestFrames`. The frame is peeled above, so
        // by the time this line runs the opener is "tighten" and the utterance
        // is the instruction it always was. What still reaches here is every
        // opener that leads a genuine question, "can we"/"could I" included,
        // because those are not frames and nothing peels them.
        if ActionClassifier.questionOpeners.contains(first) { return nil }

        // The me/us veto, lifted from `ActionClassifier` for the same reason
        // it exists there: "update me on the build" opens with a revision verb
        // and is not a revision. Unconditional here, where it is scoped to the
        // coding cohort there, because nothing in the passage vocabulary means
        // anything sensible when its target is the person speaking.
        if words.count >= 2, words[1] == "me" || words[1] == "us" { return nil }

        // THE EYELESS VETO, WHOLE-INTENT. "delete the milk reminder" and
        // "remove the three o'clock event from my calendar" open with delete
        // verbs and name things that live in EventKit, not in a document. The
        // read side already refuses to spend a pre-read on them; the write
        // side must refuse harder, because a document world that is merely
        // OPEN would otherwise volunteer a passage to delete.
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

    /// Where a spoken sentence changes direction — the boundaries a person
    /// hears even when a transcript prints no punctuation.
    ///
    /// DELIBERATELY SHORT. Every entry here widens what the `^` anchor can
    /// see, and the anchor is this file's main protection against reading a
    /// question or a piece of live composition as an edit. These four earn
    /// their place because each one ENDS a thought: a comma, an "and", and the
    /// two frames a person uses to stop describing and start asking. A wider
    /// list ("that", "which", "where") would slice inside a passage's own
    /// description — "the section that starts with I built" — and hand the
    /// shapes a fragment the user never uttered.
    public static let clauseBreaks: [String] = [
        ", ", " and then ", " and ", " so can you ", " can you ",
    ]

    /// The utterance, then each clause AROUND a break — heads first, then
    /// tails — longest context first.
    ///
    /// THE WHOLE UTTERANCE LEADS, always — so every existing verdict is
    /// reached by exactly the path it was reached by before, and clause
    /// splitting (heads and tails alike) can only ever ADD an answer where
    /// there was nil. That ordering is what makes this safe to land under
    /// the existing pins.
    ///
    /// HEADS EXIST BECAUSE OF A LIVE MISS: "reword it and put it in" produced
    /// NO intent at all. The whole utterance failed the anaphoric tail on
    /// "and"/"put"; the only emitted clause was the tail "put it in", which
    /// has no anchor; and "reword it" — the thing the user actually asked
    /// for, sitting before the break — was never tried. Heads come before
    /// tails because the head is what the user said FIRST.
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
