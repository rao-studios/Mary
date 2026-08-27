//
//  KokoroMorphology.swift
//  MaryVoice
//
//  Deterministic inflection rules over resolved stems — the tier that repairs
//  "applications", "opened", "mary's" when the lexicons carry only lemmas.
//  Suffix phoneme strings were derived empirically from 15,803 -s / 3,941 -ed /
//  4,129 -ing ground-truth pairs in the shipped G2P cache (Kokoro notation),
//  conditioned on the stem's final phoneme:
//
//    -s/'s    sibilant → ᵻz   voiceless → s   else → z
//    -ed      t/d → ᵻd        voiceless → t   else → d
//    -ing     ɪŋ      -er  əɹ      -est  ɪst      -ly  li (y-stems: i→əli)
//    un-      ʌŋ before k/ɡ, else ʌn        re-  deferred (data inconsistent)
//
//  Rules run only AFTER a 216k-lexicon + 178k-cache miss, so they only ever
//  see regular inflections — irregulars (ran, geese, read) are lexicon words.
//

import Foundation

enum KokoroMorphology {

    /// Resolve a stem through deterministic sources only (never the neural
    /// model) — supplied by the phonemizer.
    typealias Lookup = (String) -> String?

    /// Try inflection rules; returns the pronunciation and the rule name.
    static func pronounce(_ word: String, lookup: Lookup) -> (ipa: String, rule: String)? {
        guard word.count >= 3 else { return nil }

        if let hit = possessive(word, lookup) { return hit }
        if let hit = plural(word, lookup) { return hit }
        if let hit = past(word, lookup) { return hit }
        if let hit = ing(word, lookup) { return hit }
        if let hit = erEst(word, lookup) { return hit }
        if let hit = ly(word, lookup) { return hit }
        if let hit = unPrefix(word, lookup) { return hit }
        if let hit = compound(word, lookup) { return hit }
        return nil
    }

    // MARK: - Phoneme classification

    /// Kokoro-notation sibilant finals (ʧ/ʤ ligatures and tʃ/dʒ pairs both end
    /// in a member of this set at the scalar level).
    private static let sibilants: Set<Character> = ["s", "z", "ʃ", "ʒ", "ʧ", "ʤ"]
    private static let voiceless: Set<Character> = ["p", "t", "k", "f", "θ"]

    /// Last "real" phoneme scalar — stress and length marks skipped.
    static func finalPhoneme(_ ipa: String) -> Character? {
        for ch in ipa.reversed() where ch != "ˈ" && ch != "ˌ" && ch != "ː" {
            return ch
        }
        return nil
    }

    private static func pluralSuffix(after stemIPA: String) -> String {
        guard let final = finalPhoneme(stemIPA) else { return "z" }
        if sibilants.contains(final) { return "ᵻz" }
        if voiceless.contains(final) { return "s" }
        return "z"
    }

    /// Voiceless obstruents that take /t/ in -ed (t/d themselves take ᵻd).
    private static let voicelessForPast: Set<Character> = ["p", "k", "f", "θ", "s", "ʃ", "ʧ"]

    private static func pastSuffix(after stemIPA: String) -> String {
        guard let final = finalPhoneme(stemIPA) else { return "d" }
        if final == "t" || final == "d" { return "ᵻd" }
        if voicelessForPast.contains(final) { return "t" }
        return "d"
    }

    // MARK: - Rules

    private static func possessive(_ word: String, _ lookup: Lookup) -> (String, String)? {
        if word.hasSuffix("'s") {
            let stem = String(word.dropLast(2))
            guard stem.count >= 2, let ipa = lookup(stem) else { return nil }
            return (ipa + pluralSuffix(after: ipa), "'s→\(pluralSuffix(after: ipa))")
        }
        if word.hasSuffix("s'") {
            let stem = String(word.dropLast(2))
            guard stem.count >= 2, let ipa = lookup(stem) else { return nil }
            return (ipa + pluralSuffix(after: ipa), "s'→\(pluralSuffix(after: ipa))")
        }
        return nil
    }

    private static func plural(_ word: String, _ lookup: Lookup) -> (String, String)? {
        guard word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("'s") else { return nil }

        // babies → baby
        if word.hasSuffix("ies") {
            let stem = String(word.dropLast(3)) + "y"
            if stem.count >= 3, let ipa = lookup(stem) {
                // baby bˈAbi → babies bˈAbiz (final i is voiced)
                return (ipa + "z", "ies→z")
            }
        }
        // boxes → box (after s/x/z/ch/sh)
        if word.hasSuffix("es") {
            let stem = String(word.dropLast(2))
            if stem.count >= 2, let ipa = lookup(stem) {
                let suffix = pluralSuffix(after: ipa)
                return (ipa + suffix, "es→\(suffix)")
            }
        }
        // cats → cat
        let stem = String(word.dropLast(1))
        if stem.count >= 2, let ipa = lookup(stem) {
            let suffix = pluralSuffix(after: ipa)
            return (ipa + suffix, "s→\(suffix)")
        }
        return nil
    }

    private static func past(_ word: String, _ lookup: Lookup) -> (String, String)? {
        guard word.hasSuffix("ed"), word.count >= 4 else { return nil }

        // carried → carry
        if word.hasSuffix("ied") {
            let stem = String(word.dropLast(3)) + "y"
            if stem.count >= 3, let ipa = lookup(stem) {
                return (ipa + "d", "ied→d")
            }
        }
        for stem in stemCandidates(dropping: 2, from: word) {
            if let ipa = lookup(stem) {
                let suffix = pastSuffix(after: ipa)
                return (ipa + suffix, "ed→\(suffix)")
            }
        }
        return nil
    }

    private static func ing(_ word: String, _ lookup: Lookup) -> (String, String)? {
        guard word.hasSuffix("ing"), word.count >= 5 else { return nil }
        for stem in stemCandidates(dropping: 3, from: word) {
            if let ipa = lookup(stem) {
                return (ipa + "ɪŋ", "ing→ɪŋ")
            }
        }
        return nil
    }

    private static func erEst(_ word: String, _ lookup: Lookup) -> (String, String)? {
        // happier / happiest (y-stems)
        if word.hasSuffix("ier") {
            let stem = String(word.dropLast(3)) + "y"
            if stem.count >= 3, let ipa = lookup(stem), ipa.hasSuffix("i") {
                return (String(ipa.dropLast()) + "iəɹ", "ier→iəɹ")
            }
        }
        if word.hasSuffix("iest") {
            let stem = String(word.dropLast(4)) + "y"
            if stem.count >= 3, let ipa = lookup(stem), ipa.hasSuffix("i") {
                return (String(ipa.dropLast()) + "iᵻst", "iest→iᵻst")
            }
        }
        if word.hasSuffix("er"), word.count >= 4 {
            for stem in stemCandidates(dropping: 2, from: word) {
                if let ipa = lookup(stem) {
                    return (ipa + "əɹ", "er→əɹ")
                }
            }
        }
        if word.hasSuffix("est"), word.count >= 5 {
            for stem in stemCandidates(dropping: 3, from: word) {
                if let ipa = lookup(stem) {
                    return (ipa + "ɪst", "est→ɪst")
                }
            }
        }
        return nil
    }

    private static func ly(_ word: String, _ lookup: Lookup) -> (String, String)? {
        guard word.hasSuffix("ly"), word.count >= 4 else { return nil }
        // happily → happy: hˈæpi → hˈæpəli
        if word.hasSuffix("ily") {
            let stem = String(word.dropLast(3)) + "y"
            if stem.count >= 3, let ipa = lookup(stem), ipa.hasSuffix("i") {
                return (String(ipa.dropLast()) + "əli", "ily→əli")
            }
        }
        let stem = String(word.dropLast(2))
        if stem.count >= 2, let ipa = lookup(stem) {
            // final /l/ stems take bare i (usual + ly → usually pattern)
            if finalPhoneme(ipa) == "l" {
                return (ipa + "i", "ly→i")
            }
            return (ipa + "li", "ly→li")
        }
        return nil
    }

    private static func unPrefix(_ word: String, _ lookup: Lookup) -> (String, String)? {
        guard word.hasPrefix("un"), word.count >= 5 else { return nil }
        let stem = String(word.dropFirst(2))
        guard let ipa = lookup(stem) else { return nil }
        // Velar assimilation: un + k/ɡ → ʌŋ
        let first = ipa.first(where: { $0 != "ˈ" && $0 != "ˌ" })
        let prefix = (first == "k" || first == "ɡ") ? "ʌŋ" : "ʌn"
        return (prefix + ipa, "un→\(prefix)")
    }

    /// Last resort before the neural model: closed compounds ("bookshelf").
    private static func compound(_ word: String, _ lookup: Lookup) -> (String, String)? {
        guard word.count >= 7, word.allSatisfy({ $0.isLetter }) else { return nil }
        // Prefer the split with the longest first half.
        let indices = Array(word.indices.dropFirst(3).dropLast(3)).reversed()
        for index in indices {
            let a = String(word[..<index])
            let b = String(word[index...])
            guard b.count >= 3 else { continue }
            if let ipaA = lookup(a), let ipaB = lookup(b) {
                return (ipaA + " " + ipaB, "compound \(a)+\(b)")
            }
        }
        return nil
    }

    // MARK: - Stem recovery

    /// Candidates for -ed/-ing/-er/-est after dropping the suffix:
    /// bare stem ("walk"), e-restored ("bake"), de-doubled ("stop").
    private static func stemCandidates(dropping count: Int, from word: String) -> [String] {
        let bare = String(word.dropLast(count))
        guard bare.count >= 2 else { return [] }
        var candidates = [bare, bare + "e"]
        if bare.count >= 3 {
            let chars = Array(bare)
            let last = chars[chars.count - 1]
            let prev = chars[chars.count - 2]
            if last == prev, !"aeiou".contains(last) {
                candidates.append(String(bare.dropLast()))
            }
        }
        return candidates
    }
}
