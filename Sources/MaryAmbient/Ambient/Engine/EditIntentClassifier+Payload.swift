//
//  EditIntentClassifier+Payload.swift
//  MaryAmbient
//
//  WHAT: Payload extraction for revision utterances.
//  IN:   EditIntentClassifier.swift (split)
//  PIN:  A payload is never cleaned — NamedPartClassifier.clean would drop the replacement.
//

import Foundation

extension EditIntentClassifier {

    // MARK: - Payload

    /// Payload as captured. Never cleaned — `NamedPartClassifier.clean` would drop the replacement.
    static func payload(_ captured: String) -> String? {
        let trimmed = captured.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - The target ladder

    /// Ordered guesses at which passage they meant, best first. Every rung's output is cleaned.
    public static func candidates(forTarget phrase: String) -> [String] {
        var found: [String] = []

        func offer(_ raw: String?) {
            guard let raw, let cleaned = NamedPartClassifier.clean(raw) else { return }
            guard !found.contains(where: {
                $0.compare(cleaned, options: .caseInsensitive) == .orderedSame
            }) else { return }
            found.append(cleaned)
        }

        // Rung 1 — reuse `namedPart` (part-noun + connector, numbered division).
        offer(NamedPartClassifier.namedPart(in: phrase))

        // Rung 2 — container split; container outranks the sub-part.
        var containerSplitFired = false
        if let parts = captures(
            in: phrase, pattern: "^(.+?)\\s+(?:of|in|from)\\s+(.+)$"),
           parts.count == 2 {
            containerSplitFired = true
            offer(parts[1])
            offer(parts[0])
        }

        // Rung 3 — cleaned raw tail, skipped when rung 2 fired.
        if !containerSplitFired { offer(phrase) }

        // Rung 4 — strip trailing part-noun when the head is capitalised ("Purpose section" → "Purpose").
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

    /// "Purpose section" → "Purpose" when the head is capitalised and a part-noun remains.
    /// PIN: Plurals count — must agree with `namedPart`.
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

    /// Join phrases as alternation. Longest-first in the source list — nothing to escape.
    static func alternation(_ words: [String]) -> String {
        words.joined(separator: "|")
    }

    /// Strip preamble (address, alias, request frame, confirmation) without touching remaining case.
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
            // At most one leading application alias reads as an address, not a target.
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

    /// Remainder after a leading confirmation phrase, or nil. Longest phrase first.
    private static func peelConfirmation(from text: Substring) -> Substring? {
        // Longest first — "that's the one" must not lose to prefix "that one".
        for phrase in confirmationPhrases.sorted(by: { $0.count > $1.count }) {
            var cursor = text
            var matched = true
            for expected in phrase {
                let (word, after) = nextLetterRun(in: cursor)
                guard word == expected else { matched = false; break }
                cursor = after
            }
            // Every word checked before peel — same bound as `peelRequestFrame`.
            if matched { return cursor }
        }
        return nil
    }

    /// Next letter-run, stepping over apostrophes so contractions split into words.
    private static func nextLetterRun(in text: Substring) -> (String, Substring) {
        let trimmed = text.drop { !$0.isLetter }
        let word = trimmed.prefix { $0.isLetter }
        return (word.lowercased(), trimmed.dropFirst(word.count))
    }

    /// Remainder after a two-word request frame (optional "please"), or nil.
    private static func peelRequestFrame(
        from text: Substring, opening: String
    ) -> Substring? {
        guard requestFrames.contains(where: { $0.first == opening }) else { return nil }
        let (second, afterSecond) = nextWord(in: text.drop { $0.isLetter })
        guard requestFrames.contains([opening, second]) else { return nil }
        let (third, afterThird) = nextWord(in: afterSecond)
        return third == politeTail ? afterThird : afterSecond
    }

    /// Next word lowercased, skipping the same whitespace and commas as `stripPreamble`.
    private static func nextWord(in text: Substring) -> (String, Substring) {
        let trimmed = text.drop { $0.isWhitespace || $0 == "," }
        let word = trimmed.prefix { $0.isLetter }
        return (word.lowercased(), trimmed.dropFirst(word.count))
    }

    /// Capture groups of the first match, or nil. Kept identical to `NamedPartClassifier`'s helper.
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
