//
//  EditIntentClassifier+Payload.swift
//  MaryAmbient
//
//  Split out of EditIntentClassifier.swift (docs/DECOMPOSITION.md
//  Wave 4) — pure relocation, no declaration changed.
//

import Foundation

extension EditIntentClassifier {

    // MARK: - Payload

    /// THE ASYMMETRY, AND IT IS DELIBERATE: A PAYLOAD IS NEVER CLEANED.
    ///
    /// `NamedPartClassifier.clean` drops the leading article, stops at a
    /// clause break, clips to five words and strips trailing fillers. Every
    /// one of those is right for a phrase we are about to hand to `find` — a
    /// whole spoken sentence matches nothing in a document. Every one of them
    /// is destructive for prose the user wants WRITTEN: "the tighter version"
    /// would lose its article, a thirty-word replacement would arrive as six,
    /// and a sentence ending in "again" would end one word early and in the
    /// document forever.
    ///
    /// So the two halves of a replacement are treated as opposites on purpose.
    /// The target is clipped because it has to be findable; the payload passes
    /// through untouched but for the whitespace around it, because it has to
    /// be exactly what they said.
    static func payload(_ captured: String) -> String? {
        let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The target ladder

    /// Ordered guesses at which passage they meant, best first.
    ///
    /// Four rungs, each one a strictly different reading of the same phrase,
    /// and every rung's output passes `NamedPartClassifier.clean` — which is
    /// also rung 5, the drop: `clean` already refuses a pronoun ("delete
    /// that"), a bare article and a one-character phrase, and those are
    /// exactly the candidates a resolver must never be handed. Re-implementing
    /// that judgement here would give the read side and the write side two
    /// different opinions about what identifies nothing.
    public static func candidates(forTarget phrase: String) -> [String] {
        var found: [String] = []

        func offer(_ raw: String?) {
            guard let raw, let cleaned = NamedPartClassifier.clean(raw) else { return }
            guard !found.contains(where: {
                $0.compare(cleaned, options: .caseInsensitive) == .orderedSame
            }) else { return }
            found.append(cleaned)
        }

        // RUNG 1 — REUSE FIRST. `namedPart` already solves the part-noun +
        // connector shape ("the paragraph about batteries" → "batteries") and
        // the numbered-division shape ("section five" → "section 5", the form
        // a document actually prints). Both arrive here with no new regex at
        // all, and they arrive spelled the way the read side spells them.
        offer(NamedPartClassifier.namedPart(in: phrase))

        // RUNG 2 — CONTAINER SPLIT, AND THE CONTAINER OUTRANKS THE SUB-PART.
        // "the last two sentences of the intro": "intro" is a thing a document
        // contains and "last two sentences" is a description of a position, so
        // the findable half leads and the positional half follows as the
        // runner-up. This is the ordering the widening ladder needs — it can
        // locate the intro and then count sentences inside it, but it can
        // never search for "last two sentences".
        var containerSplitFired = false
        if let parts = captures(
            in: phrase, pattern: "^(.+?)\\s+(?:of|in|from)\\s+(.+)$"),
           parts.count == 2 {
            containerSplitFired = true
            offer(parts[1])
            offer(parts[0])
        }

        // RUNG 3 — the cleaned raw tail, SKIPPED when rung 2 fired. After a
        // container split the raw tail is just the two halves with a
        // preposition between them, and `clean`'s five-word clip turns it into
        // a phrase ending on a dangling article ("last two sentences of the")
        // that no document contains. A candidate that cannot match is not a
        // wider read, it is a wasted rung.
        if !containerSplitFired { offer(phrase) }

        // RUNG 4 — TRAILING PART-NOUN STRIP, CONDITIONAL ON CAPITALISATION.
        // A document prints the heading "Purpose", not "Purpose section", so
        // "the Purpose section" wants "Purpose" tried first. But "the opening
        // paragraph" must stay whole: "opening" is a description, stripping it
        // bare would search for a common word and hit the wrong place with
        // confidence. Capitalisation is the evidence that separates them, and
        // it survives intact because nothing in this ladder lowercases —
        // `clean` preserves case for exactly this reason.
        var headings: [String] = []
        for candidate in found {
            guard let stripped = headingForm(of: candidate),
                  let cleaned = NamedPartClassifier.clean(stripped) else { continue }
            let known = (found + headings).contains {
                $0.compare(cleaned, options: .caseInsensitive) == .orderedSame
            }
            if !known { headings.append(cleaned) }
        }
        found = headings + found

        return Array(found.prefix(maxCandidates))
    }

    /// "Purpose section" → "Purpose", but only when the head is capitalised in
    /// the utterance and something is left after the strip. Plurals count:
    /// `namedPart`'s own pattern matches "sentences" as a part-noun, and the
    /// two must agree.
    private static func headingForm(of candidate: String) -> String? {
        let words = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, let last = words.last else { return nil }
        let bare = last.trimmingCharacters(
            in: CharacterSet.alphanumerics.inverted).lowercased()
        let singular = bare.hasSuffix("s") ? String(bare.dropLast()) : bare
        guard NamedPartClassifier.partNouns.contains(bare)
                || NamedPartClassifier.partNouns.contains(singular) else { return nil }
        let head = words.dropLast()
        guard let first = head.last?.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first) else { return nil }
        return head.joined(separator: " ")
    }

    // MARK: - Plumbing

    static func anchor(for marker: String) -> EditIntent.Anchor? {
        anchorVocabulary.first { $0.phrase == marker }?.anchor
    }

    /// Alternation branches are plain words and spaces by construction, so
    /// there is nothing to escape — but they are joined in list order, which
    /// is why every vocabulary above is written longest-phrase-first.
    static func alternation(_ words: [String]) -> String {
        words.joined(separator: "|")
    }

    /// THE PREAMBLE STRIP — everything a person says before they start saying
    /// what they want, peeled in `ActionClassifier`'s loop shape from a string
    /// whose case is otherwise untouched. Case has to survive: rung 4 of the
    /// target ladder reads it as evidence of a heading.
    ///
    /// Three kinds, peeled in any order and any number of times, because that
    /// is how they are spoken: an address ("hey mary"), backchannel ("yeah
    /// yeah exactly") and a polite request frame ("can you", "could you please").
    /// The live utterance carried all three at once.
    ///
    /// THIS IS THE ONE STRIP THAT WIDENED. `ActionClassifier`'s stayed at four
    /// address words on purpose — its `questionOpeners` veto on polite forms is
    /// deliberate there ("can you add a pink case" wants an answer, and the cost
    /// of being wrong is a silenced reply), and widening a shared vocabulary
    /// would change the rhythm for every consumer of it.
    /// PUBLIC because a second consumer needs the same answer, not a second
    /// copy of it: `OfferedProse.acceptsClause` has to strip "oh please can
    /// you" off an acceptance before it can see the verb, and a hand-rolled
    /// peel there would drift from this vocabulary the first time a polite
    /// form was added to one and not the other. It is a pure string function
    /// with no state; exporting it grants nothing but the peel.
    public static func stripPreamble(
        _ text: String,
        applicationAliases: Set<String> = []
    ) -> String {
        var remainder = Substring(text)
        var peeledAlias = false
        while true {
            let trimmed = remainder.drop { $0.isWhitespace || $0 == "," }
            let word = trimmed.prefix { $0.isLetter }
            guard !word.isEmpty else { return String(trimmed) }
            let lowered = word.lowercased()
            if addressWords.contains(lowered) || backchannelWords.contains(lowered) {
                remainder = trimmed.dropFirst(word.count)
                continue
            }
            // AT MOST ONE leading application alias reads as an address —
            // "Sketch, replace the intro…" is the same instruction as
            // "mary, replace the intro…", and only the alias in FRONT can
            // be an address rather than a target.
            if !peeledAlias, applicationAliases.contains(lowered) {
                peeledAlias = true
                remainder = trimmed.dropFirst(word.count)
                continue
            }
            if let afterFrame = peelRequestFrame(from: trimmed, opening: lowered) {
                remainder = afterFrame
                continue
            }
            if let afterPhrase = peelConfirmation(from: trimmed) {
                remainder = afterPhrase
                continue
            }
            return String(trimmed)
        }
    }

    /// What follows a leading confirmation phrase, or nil when none leads.
    ///
    /// Longest phrase first, so "that's the one" is not half-peeled by a
    /// shorter entry that happens to prefix it. EVERY word is checked before
    /// anything is peeled — the same bound `peelRequestFrame` uses — so
    /// "that's the wrong paragraph" matches nothing and reaches the shapes
    /// exactly as the user said it.
    private static func peelConfirmation(from text: Substring) -> Substring? {
        // LONGEST FIRST, so "that's the one" is never half-peeled by the
        // shorter "that one" that prefixes its token stream.
        for phrase in confirmationPhrases.sorted(by: { $0.count > $1.count }) {
            var cursor = text
            var matched = true
            for expected in phrase {
                let (word, after) = nextLetterRun(in: cursor)
                guard word == expected else { matched = false; break }
                cursor = after
            }
            // EVERY word checked before anything is peeled — the same bound
            // `peelRequestFrame` uses, and what keeps "that's the wrong
            // paragraph" reaching the shapes exactly as it was said.
            if matched { return cursor }
        }
        return nil
    }

    /// `nextWord`, but stepping over an apostrophe as well as whitespace, so a
    /// contraction reads as its letter runs.
    private static func nextLetterRun(in text: Substring) -> (String, Substring) {
        let trimmed = text.drop { !$0.isLetter }
        let word = trimmed.prefix { $0.isLetter }
        return (word.lowercased(), trimmed.dropFirst(word.count))
    }

    /// What follows a two-word request frame — plus its optional "please" —
    /// or nil when no frame leads `text`. BOTH words are checked before
    /// anything is peeled, which is the whole bound: "what did you replace"
    /// opens on a word that is in no frame at all, so it survives to the
    /// question-opener veto exactly as it always did.
    private static func peelRequestFrame(
        from text: Substring, opening: String
    ) -> Substring? {
        guard requestFrames.contains(where: { $0.first == opening }) else { return nil }
        let (second, afterSecond) = nextWord(in: text.drop { $0.isLetter })
        guard requestFrames.contains([opening, second]) else { return nil }
        let (third, afterThird) = nextWord(in: afterSecond)
        return third == politeTail ? afterThird : afterSecond
    }

    /// The next word lowercased and what follows it, skipping the same
    /// whitespace and commas `stripPreamble`'s loop skips — one rule about
    /// where a word begins, so the frame peel and the loop cannot disagree.
    private static func nextWord(in text: Substring) -> (String, Substring) {
        let trimmed = text.drop { $0.isWhitespace || $0 == "," }
        let word = trimmed.prefix { $0.isLetter }
        return (word.lowercased(), trimmed.dropFirst(word.count))
    }

    /// Every capture group of the FIRST match, or nil when nothing matched.
    /// A near-copy of `NamedPartClassifier`'s helper, which is private there;
    /// the two are kept identical on purpose so a pattern that behaves one way
    /// on the read side behaves the same way here.
    static func captures(in text: String, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges > 1 else { return nil }
        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            guard let groupRange = Range(match.range(at: index), in: text) else { continue }
            groups.append(String(text[groupRange]))
        }
        return groups.isEmpty ? nil : groups
    }
}
