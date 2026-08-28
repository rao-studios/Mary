//
//  SpokenTitleMatcher.swift
//  MaryBrain
//
//  A SPOKEN NAME AGAINST A LIST OF REAL TITLES — the resolution every adapter
//  that takes "play the Pt. 3 playlist" by voice needs and none had.
//
//  THE LIVE FAILURE THIS FIXES: the user said "Part 3", the ASR wrote
//  "part tree", and the playlist is titled "Pt. 3". The adapter handed the raw
//  transcript to an exact AppleScript by-name specifier, which can never cross
//  any of those three gaps: the abbreviation (Pt ↔ part), the number form
//  (3 ↔ three), or the mishearing (tree ≈ three). "I couldn't find a playlist
//  called part tree" — at a library that has exactly one plausible answer.
//
//  THE LADDER, first rung with survivors decides:
//
//    1 exact fold        case/diacritics only — "rao" is "RAO"
//    2 canonical         both sides through the full canonical form below
//    3 containment       the spoken tokens appear, in order, inside the title
//                        (or the title inside the speech: "the Pt. 3 one")
//    4 overlap           every spoken token appears somewhere in the title
//    5 repair            rungs 2–4 rerun, letting token PAIRS differ by one
//                        edit when both are long enough to make that safe —
//                        this is the rung that hears "tree" as "three"
//    6 intent focus      only after the original ladder has no survivors,
//                        peel a spoken request prefix ("please play my") and
//                        rerun it. The title words themselves stay intact, so
//                        "play the playlist Breakfast Office" can still match
//                        the literal title "Breakfast Office Playlist"
//
//  One survivor is a match. Two or more STOPS — the caller names them and
//  plays nothing, because guessing between "Morning Mix" and "Morning Run"
//  is how the wrong music starts. Zero names the closest misses so the reply
//  is useful rather than a shrug.
//
//  THE CANONICAL FORM: `&`→"and" (FoldedText drops symbols, so first), then
//  `PassageWidening.fold` (case/diacritics), then `FoldedText` (punctuation —
//  "Pt." → "pt"), then per-token abbreviation expansion, then digits →
//  number-WORDS. The word form is canonical, not the digit form, because the
//  repair rung works on edit distance and "tree"→"three" is one insertion
//  while "tree"→"3" is unreachable. `NamedPartClassifier.spokenNumbers` is
//  reused REVERSED — it maps words to digits for document headings; titles
//  need the opposite direction for exactly the mirrored reason.
//

import Foundation

public enum SpokenTitleMatcher {

    public enum Resolution: Equatable, Sendable {
        /// The candidate's REAL title, ready for an exact specifier.
        case match(String)
        /// Two or more titles survived the same rung — name them, play nothing.
        case ambiguous([String])
        /// Nothing survived; the closest misses by token overlap, best first.
        case none(closest: [String])
    }

    /// Small and each entry earned by a music title it appears in. `no` is
    /// guarded at expansion time (only before a number token) because bare
    /// "no" is negation, not "number". `st` is deliberately absent —
    /// street/saint is unresolvable without context.
    static let abbreviations: [String: String] = [
        "pt": "part", "vol": "volume", "ft": "featuring", "feat": "featuring",
        "mr": "mister", "dr": "doctor", "vs": "versus", "no": "number",
    ]

    /// Digits → words, 0–20. The reverse of `NamedPartClassifier.spokenNumbers`
    /// plus zero, kept beside the ladder that owns the reason for the
    /// direction.
    static let digitWords: [String: String] = {
        var table = ["0": "zero"]
        for (word, digit) in NamedPartClassifier.spokenNumbers {
            table[digit] = word
        }
        return table
    }()

    /// Request language that may precede a title when a caller hands us more
    /// than the bare tool argument. These are PHRASES, not global stop words:
    /// only a leading occurrence is removed. That distinction preserves a
    /// real title such as "Play It Again" while still focusing "please play
    /// the playlist Breakfast Office" on its named object.
    private static let requestLeadInPhrases: [[String]] = [
        ["i", "would", "like", "to"], ["i", "d", "like", "to"],
        ["i", "want", "to"], ["could", "you"], ["would", "you"],
        ["can", "you"], ["will", "you"],
        ["open", "apple", "music", "and"],
        ["please"],
    ]

    /// Exactly ONE of these is consumed. Repeatedly treating "play" as a
    /// command would turn "please play Play It Again" into just "it again".
    private static let playbackCommandPhrases: [[String]] = [
        ["start", "playing"], ["listen", "to"], ["put", "on"],
        ["play"], ["start"], ["hear"],
    ]

    /// These can be request grammar or the first word of a real title. The
    /// focused ladder therefore tries the preserved form first, then peels
    /// these one at a time as progressively broader variants.
    private static let optionalIntentPhrases: [[String]] = [
        ["apple", "music"], ["the"], ["my"], ["a"], ["an"], ["some"],
    ]

    /// A kind word alone is an intent, not a title. The focused fallback must
    /// retain at least one specific word or "please play a playlist" could
    /// select the sole playlist in a small library by accident.
    private static let mediaKindTokens: Set<String> = [
        "playlist", "playlists", "music", "song", "songs", "album", "albums",
        "artist", "artists", "track", "tracks",
    ]

    private static let nonspecificIntentTokens = mediaKindTokens.union([
        "a", "an", "the", "my", "some", "called", "named", "titled",
    ])

    public static func resolve(_ spoken: String, in candidates: [String]) -> Resolution {
        let trimmed = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.isEmpty else {
            return .none(closest: Array(candidates.prefix(3)))
        }

        // Rung 1 — exact fold.
        let foldedSpoken = PassageWidening.fold(trimmed)
        let exact = candidates.filter { PassageWidening.fold($0) == foldedSpoken }
        if let decided = decide(exact) { return decided }

        let spokenTokens = canonicalTokens(trimmed)
        guard !spokenTokens.isEmpty else {
            return .none(closest: Array(candidates.prefix(3)))
        }
        let focusedIntent = intentFocusedTokenVariants(spokenTokens)
        if !focusedIntent.isEmpty,
           focusedIntent.allSatisfy({ variant in
               !variant.contains(where: { !nonspecificIntentTokens.contains($0) })
           }) {
            return .none(closest: Array(candidates.prefix(3)))
        }
        let candidateTokens = candidates.map { ($0, canonicalTokens($0)) }

        // Rungs 2–4, strict equality between tokens.
        for rung in [equalityRung, containmentRung, overlapRung] {
            let hits = candidateTokens
                .filter { rung(spokenTokens, $0.1, false) }
                .map(\.0)
            if let decided = decide(hits) { return decided }
        }
        // Rung 5 — the same three shapes, letting token pairs differ by one
        // edit when both sides are ≥4 characters. "tree"≈"three" repairs;
        // "no"≈"on" never does.
        for rung in [equalityRung, containmentRung, overlapRung] {
            let hits = candidateTokens
                .filter { rung(spokenTokens, $0.1, true) }
                .map(\.0)
            if let decided = decide(hits) { return decided }
        }

        // Rung 6 — callers usually pass a bare title, but model-authored tool
        // arguments occasionally retain request grammar or move the kind word
        // ahead of the name: "play the playlist Breakfast Office". Removing
        // only a LEADING intent prefix lets order-free overlap see the literal
        // trailing "Playlist" in "Breakfast Office Playlist". This is last so
        // every exact and established fuzzy decision above remains unchanged.
        let focusedVariants = focusedIntent
            .filter { $0.contains(where: { !nonspecificIntentTokens.contains($0) }) }
        for fuzzy in [false, true] {
            for focusedTokens in focusedVariants {
                for rung in [equalityRung, containmentRung, overlapRung] {
                    let hits = candidateTokens
                        .filter { rung(focusedTokens, $0.1, fuzzy) }
                        .map(\.0)
                    if let decided = decide(hits) { return decided }
                }
            }
        }

        // Nothing. Name the closest misses so the reply teaches the real
        // titles instead of shrugging.
        let scored = candidateTokens
            .map { title, tokens -> (String, Int) in
                let hits = spokenTokens.filter { spoken in
                    tokens.contains { tokensMatch($0, spoken, fuzzy: true) }
                }
                return (title, hits.count)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        return .none(closest: scored.prefix(3).map(\.0))
    }

    // MARK: - The canonical form

    /// Public alongside `resolve` — an adapter that searches an app's own
    /// engine (Music's `search`) wants the canonical spelling of the QUERY
    /// even when the candidate list lives on the far side of that engine.
    public static func canonicalTokens(_ text: String) -> [String] {
        // `&` first: FoldedText treats it as a symbol and would delete it,
        // and "Rock & Roll" must canonicalize to the words a voice says.
        let anded = text.replacingOccurrences(of: "&", with: " and ")
        let folded = String(FoldedText(PassageWidening.fold(anded)).characters)
        var tokens = folded.split(separator: " ").map(String.init)
        for index in tokens.indices {
            if let expanded = abbreviations[tokens[index]] {
                // "no" is negation unless a number follows it.
                if tokens[index] == "no" {
                    let next = tokens.indices.contains(index + 1) ? tokens[index + 1] : ""
                    let numberFollows = digitWords[next] != nil
                        || NamedPartClassifier.spokenNumbers[next] != nil
                    if !numberFollows { continue }
                }
                tokens[index] = expanded
            }
            if let word = digitWords[tokens[index]] {
                tokens[index] = word
            }
        }
        return tokens
    }

    /// Focus a full spoken request into the portion that can be a title.
    /// Structural cues immediately after "playlist" are removed, but the
    /// word "playlist" itself is deliberately retained: it may be part of the
    /// real title, as in "Breakfast Office Playlist".
    private static func intentFocusedTokenVariants(_ tokens: [String]) -> [[String]] {
        var focused = tokens
        var removedRequestLanguage = false

        while let phrase = requestLeadInPhrases.first(where: {
            focused.starts(with: $0)
        }) {
            focused.removeFirst(phrase.count)
            removedRequestLanguage = true
        }
        if let command = playbackCommandPhrases.first(where: {
            focused.starts(with: $0)
        }) {
            focused.removeFirst(command.count)
            removedRequestLanguage = true
        }

        var variants: [[String]] = []
        func appendVariant(_ raw: [String], changed: Bool) {
            let cleaned = removeStructuralCues(from: raw)
            guard (changed || cleaned != tokens), !cleaned.isEmpty,
                  !variants.contains(cleaned) else { return }
            variants.append(cleaned)
        }
        appendVariant(focused, changed: removedRequestLanguage)

        // Preserve a possible title word first. Only if that form finds
        // nothing does the resolver try treating it as grammar/app context.
        while let optional = optionalIntentPhrases.first(where: {
            focused.starts(with: $0)
        }) {
            focused.removeFirst(optional.count)
            appendVariant(focused, changed: true)
        }
        return variants
    }

    private static func removeStructuralCues(from tokens: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(tokens.count)
        for token in tokens {
            let previousIsPlaylist = result.last == "playlist" || result.last == "playlists"
            if previousIsPlaylist, ["called", "named", "titled"].contains(token) {
                continue
            }
            result.append(token == "playlists" ? "playlist" : token)
        }
        return result
    }

    // MARK: - Rungs

    private static let equalityRung: ([String], [String], Bool) -> Bool = { spoken, title, fuzzy in
        spoken.count == title.count
            && zip(spoken, title).allSatisfy { tokensMatch($0, $1, fuzzy: fuzzy) }
    }

    /// The spoken tokens as a CONTIGUOUS run inside the title, or the title
    /// inside the speech — word-boundary containment in token space, the
    /// same rule `ReferenceResolver.mentions` enforces in character space.
    private static let containmentRung: ([String], [String], Bool) -> Bool = { spoken, title, fuzzy in
        contains(title, run: spoken, fuzzy: fuzzy) || contains(spoken, run: title, fuzzy: fuzzy)
    }

    /// Every spoken token appears SOMEWHERE in the title — order-free, for
    /// "part three" against "My Mix, Pt. 3".
    private static let overlapRung: ([String], [String], Bool) -> Bool = { spoken, title, fuzzy in
        spoken.allSatisfy { token in
            title.contains { tokensMatch($0, token, fuzzy: fuzzy) }
        }
    }

    private static func contains(_ haystack: [String], run needle: [String], fuzzy: Bool) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        for start in 0...(haystack.count - needle.count) {
            let window = haystack[start..<(start + needle.count)]
            if zip(window, needle).allSatisfy({ tokensMatch($0, $1, fuzzy: fuzzy) }) {
                return true
            }
        }
        return false
    }

    static func tokensMatch(_ a: String, _ b: String, fuzzy: Bool) -> Bool {
        if a == b { return true }
        guard fuzzy, a.count >= 4, b.count >= 4 else { return false }
        return editDistance(a, b) <= 1
    }

    private static func decide(_ hits: [String]) -> Resolution? {
        switch hits.count {
        case 0: return nil
        case 1: return .match(hits[0])
        default: return .ambiguous(hits)
        }
    }

    /// Plain Levenshtein over unicode scalars. The one in the tree lives in
    /// MaryVoice's phonemizer benchmarks, a package this one cannot see —
    /// and fifteen lines is cheaper than a dependency edge.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a.unicodeScalars)
        let bChars = Array(b.unicodeScalars)
        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)
        for (i, aChar) in aChars.enumerated() {
            current[0] = i + 1
            for (j, bChar) in bChars.enumerated() {
                current[j + 1] = min(
                    previous[j + 1] + 1,
                    current[j] + 1,
                    previous[j] + (aChar == bChar ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
