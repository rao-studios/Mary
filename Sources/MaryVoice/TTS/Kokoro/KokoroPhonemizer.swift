//
//  KokoroPhonemizer.swift
//  MaryVoice
//
//  Converts English text → Kokoro phoneme token IDs, tracing every word.
//
//  Text level:   SSML strip → text normalization (numbers, times, abbrev.) → word split
//  Per word:     ssml → custom → exact-case lexicon/cache → acronym gate →
//                lexicon (lower/capitalized) → G2P cache → hyphen split →
//                morphology rules → neural G2P → spell-out → salvage → dropped
//
//  Nothing is ever silently dropped: every word lands in the
//  PronunciationReport with the tier that produced (or failed to produce) it.
//

import Foundation
import NaturalLanguage

final class KokoroPhonemizer {
    /// word → IPA string (gold/silver lexicons, flattened to DEFAULT).
    private var lexicon: [String: String] = [:]
    /// word → variant tag → IPA, for the ~790 heteronym entries (POS phase).
    private(set) var variantLexicon: [String: [String: String]] = [:]
    /// IPA Unicode scalar string → token ID.
    private var vocab: [String: Int] = [:]
    /// User-supplied overrides (take priority over lexicon).
    private var customLexicon: [String: String] = [:]
    /// Optional G2P — cache tier + neural model tier.
    var g2p: KokoroG2P?
    /// Legacy console chatter; the report is the real observability channel.
    var verboseLogging = false

    private var warnedAboutSpaceToken = false

    // MARK: - Loading

    /// Load `vocab_index.json` — expects `{"vocab": {"<char>": <id>, ...}}`
    func loadVocab(from url: URL) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let v = json["vocab"] as? [String: Int] else {
            throw TTSError.phonemizationFailed
        }
        self.vocab = v
        if verboseLogging { print("📚 Loaded vocab: \(v.count) entries") }
    }

    /// Load a pronunciation dictionary (us_gold.json / gb_gold.json / …).
    /// Format: `{"word": "IPA", ...}` or `{"word": {"DEFAULT": "IPA", "VERB": "IPA", …}, ...}`
    /// Later calls merge into the existing lexicon (earlier = higher priority).
    func loadLexicon(from url: URL, overwrite: Bool = false) throws {
        let data = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TTSError.phonemizationFailed
        }

        var added = 0
        for (word, value) in json {
            if let ipa = value as? String {
                guard overwrite || lexicon[word] == nil else { continue }
                lexicon[word] = ipa; added += 1
            } else if let variants = value as? [String: Any] {
                // Keep the whole variant dict (nulls skipped) for POS selection,
                // and flatten DEFAULT into the fast path.
                var kept: [String: String] = [:]
                for (tag, variant) in variants {
                    if let ipa = variant as? String { kept[tag] = ipa }
                }
                if !kept.isEmpty, variantLexicon[word] == nil {
                    variantLexicon[word] = kept
                }
                if let defaultIPA = kept["DEFAULT"], overwrite || lexicon[word] == nil {
                    lexicon[word] = defaultIPA; added += 1
                }
            }
        }
        if verboseLogging {
            print("📖 Loaded lexicon '\(url.lastPathComponent)': \(added) entries (total \(lexicon.count))")
        }
    }

    // MARK: - Custom pronunciations

    /// Register a pronunciation override that takes priority over the built-in
    /// lexicon. `ipa` uses the same character set as the loaded vocab.
    func addCustomPronunciation(_ word: String, ipa: String) {
        customLexicon[word.lowercased()] = ipa
    }

    // MARK: - SSML preprocessing

    /// Strip SSML `<phoneme alphabet="ipa" ph="…">word</phoneme>` tags,
    /// returning cleaned text plus a per-call override dictionary.
    func preprocessSSML(_ text: String) -> (cleanText: String, overrides: [String: String]) {
        var overrides: [String: String] = [:]

        let pattern = #"<phoneme\b[^>]*\bph="([^"]+)"[^>]*>(.*?)</phoneme>"#
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return (text, overrides)
        }

        var cleanText = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        for match in matches.reversed() {
            guard match.numberOfRanges == 3,
                  let ipaRange  = Range(match.range(at: 1), in: text),
                  let wordRange = Range(match.range(at: 2), in: text),
                  let fullRange = Range(match.range(at: 0), in: text) else { continue }

            let ipa  = String(text[ipaRange])
            let word = String(text[wordRange])
            overrides[word.lowercased()] = ipa
            cleanText = cleanText.replacingCharacters(in: fullRange, with: word)
        }
        return (cleanText, overrides)
    }

    // MARK: - Phonemization

    /// Convert text to Kokoro token IDs with a full per-word trace.
    /// Returns `[BOS=0, …ids…, EOS=0]` (unpadded — caller pads to maxTokens)
    /// plus the PronunciationReport.
    func phonemize(_ text: String, maxTokens: Int) async -> (ids: [Int32], report: PronunciationReport) {
        let (cleanText, ssmlOverrides) = preprocessSSML(text)
        let (normalized, substitutions) = KokoroTextNormalizer.normalize(cleanText)
        let words = splitWords(normalized)

        var report = PronunciationReport(text: text, normalizedText: normalized)
        var unmapped: Set<String> = []
        var phonemeIDs: [Int32] = []
        var originQueue = OriginQueue(substitutions: substitutions)

        // POS tags are only computed when the sentence contains a heteronym
        // (1,392 lexicon entries carry distinct NOUN/VERB/ADJ variants).
        let posTags: [String?]
        if words.contains(where: { variantLexicon[$0.lowercased()] != nil }) {
            posTags = Self.lexicalClasses(for: normalized, alignedWith: words)
        } else {
            posTags = Array(repeating: nil, count: words.count)
        }

        for (index, word) in words.enumerated() {
            var entry = await resolve(word, ssmlOverrides: ssmlOverrides, posTag: posTags[index])
            entry.original = originQueue.originFor(word: word)

            if !entry.ipa.isEmpty {
                let wordIDs = tokenIDs(forIPA: entry.ipa, unmapped: &unmapped)
                entry.tokenCount = wordIDs.count
                if !wordIDs.isEmpty {
                    if !phonemeIDs.isEmpty, let space = spaceTokenID() {
                        phonemeIDs.append(space)
                    }
                    phonemeIDs.append(contentsOf: wordIDs)
                }
            }
            report.words.append(entry)
        }

        // Sentence-final punctuation (from the normalized text) carries prosody.
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if let last = trimmed.last, ".!?,".contains(last), let id = vocab[String(last)] {
            phonemeIDs.append(Int32(id))
        }

        // Truncate to leave room for BOS + EOS.
        let capacity = maxTokens - 2
        if phonemeIDs.count > capacity {
            phonemeIDs = Array(phonemeIDs.prefix(capacity))
        }

        var result: [Int32] = [0]
        result.append(contentsOf: phonemeIDs)
        result.append(0)

        report.unmappedScalars = unmapped.sorted()
        report.totalTokens = result.count

        if verboseLogging {
            print("🔤 '\(text.prefix(50))' → \(phonemeIDs.count) phoneme tokens (total ids: \(result.count))")
            for concern in report.concerns {
                print("  ⚠️ '\(concern.word)' → \(concern.source.rawValue)")
            }
        }
        return (result, report)
    }

    /// Legacy entry point — ids only.
    func tokenIDs(for text: String, maxTokens: Int) async -> [Int32] {
        await phonemize(text, maxTokens: maxTokens).ids
    }

    // MARK: - The tier ladder

    private func resolve(
        _ word: String,
        ssmlOverrides: [String: String],
        posTag: String? = nil
    ) async -> WordPronunciation {
        let lower = word.lowercased()

        // 1. SSML inline override
        if let ipa = ssmlOverrides[lower] {
            return WordPronunciation(word: word, source: .ssml, ipa: ipa, tokenCount: 0)
        }
        // 2. Custom lexicon
        if let ipa = customLexicon[lower] {
            return WordPronunciation(word: word, source: .custom, ipa: ipa, tokenCount: 0)
        }
        // 2.5 Heteronym variant — must beat the flat DEFAULT lookup below.
        if let posTag,
           let variants = variantLexicon[lower] ?? variantLexicon[word],
           let ipa = variants[posTag], ipa != variants["DEFAULT"] {
            return WordPronunciation(word: word, source: .lexiconVariant, ipa: ipa, tokenCount: 0, detail: posTag)
        }
        // 3. Exact-case lexicon, then exact-case cache (NASA, OK, …)
        if let ipa = lexicon[word] {
            return WordPronunciation(word: word, source: .lexicon, ipa: ipa, tokenCount: 0, detail: "exact")
        }
        if let ipa = g2p?.caseSensitiveCachedPhonemes(for: word) {
            return WordPronunciation(word: word, source: .cache, ipa: ipa, tokenCount: 0, detail: "exact-case")
        }
        // 4. Acronym gate — BEFORE the capitalization fallback, so "VS" can
        //    never resolve through gold's "Vs" (= "veez").
        if isSpellableAcronym(word) {
            if let ipa = spellOut(lower) {
                return WordPronunciation(word: word, source: .spelled, ipa: ipa, tokenCount: 0, detail: "acronym")
            }
        }
        // 5. Lexicon: lowercase, then Capitalized key
        if let ipa = lexicon[lower] {
            return WordPronunciation(word: word, source: .lexicon, ipa: ipa, tokenCount: 0)
        }
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        if let ipa = lexicon[capitalized] {
            return WordPronunciation(word: word, source: .lexicon, ipa: ipa, tokenCount: 0, detail: "capitalized")
        }
        // 6. G2P cache (lowercase section)
        if let ipa = g2p?.cachedPhonemes(for: lower) {
            return WordPronunciation(word: word, source: .cache, ipa: ipa, tokenCount: 0)
        }
        // 7. Hyphenated: resolve each part deterministically
        if word.contains("-"), let ipa = pronounceHyphenated(word) {
            return WordPronunciation(word: word, source: .lexicon, ipa: ipa, tokenCount: 0, detail: "hyphenated")
        }
        // 8. Morphology: inflection rules over a resolved stem
        if let (ipa, rule) = KokoroMorphology.pronounce(lower, lookup: { [weak self] stem in
            self?.deterministicLookup(stem)
        }) {
            return WordPronunciation(word: word, source: .morphology, ipa: ipa, tokenCount: 0, detail: rule)
        }
        // 9. Neural G2P
        if let ipa = await g2p?.modelPhonemes(for: lower), !ipa.isEmpty {
            return WordPronunciation(word: word, source: .g2p, ipa: ipa, tokenCount: 0)
        }
        // 10. Spell-out (letters + digits)
        if let ipa = spellOut(lower) {
            return WordPronunciation(word: word, source: .spelled, ipa: ipa, tokenCount: 0)
        }
        // 11. Salvage: strip unpronounceable scalars and retry
        let salvagedText = String(lower.unicodeScalars.filter {
            ("a"..."z").contains(String($0)) || ("0"..."9").contains(String($0)) || $0 == "'"
        })
        if !salvagedText.isEmpty, salvagedText != lower {
            if let ipa = deterministicLookup(salvagedText) ?? spellOut(salvagedText) {
                return WordPronunciation(word: word, source: .salvaged, ipa: ipa, tokenCount: 0, detail: salvagedText)
            }
        }
        // 12. Dropped — traced, never silent.
        return WordPronunciation(word: word, source: .dropped, ipa: "", tokenCount: 0)
    }

    /// Stems/parts must come from deterministic sources only (never the
    /// neural model): custom → exact → lower → Capitalized → cache.
    func deterministicLookup(_ word: String) -> String? {
        let lower = word.lowercased()
        if let ipa = customLexicon[lower] { return ipa }
        if let ipa = lexicon[word] { return ipa }
        if let ipa = lexicon[lower] { return ipa }
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        if let ipa = lexicon[capitalized] { return ipa }
        return g2p?.cachedPhonemes(for: lower)
    }

    // MARK: - Acronyms

    /// Curated tokens whose lowercase form exists in the data but misleads
    /// ("vs" → "veez") or reads wrong as a word.
    private static let acronymSpellList: Set<String> = [
        "VS", "PDF", "URL", "API", "CEO", "CTO", "CFO", "COO", "FAQ", "FYI",
        "ETA", "ATM", "GPS", "USB", "HTML", "CSS", "JSON", "XML", "SDK", "CLI",
        "GPU", "CPU", "RAM", "SSD", "HTTP", "HTTPS", "SQL", "AWS", "IDE", "PR",
        "QA", "DNS", "VPN", "LLM", "TTS", "STT", "VAD",
    ]

    /// ALL-CAPS alphabetic tokens spell out when they're on the curated list,
    /// or when no word form exists at all (true OOV acronyms). Shouting-caps
    /// real words ("THIS", "IT") fall through to the word tiers.
    private func isSpellableAcronym(_ word: String) -> Bool {
        guard word.count >= 2, word.count <= 5,
              word.allSatisfy({ $0.isLetter && $0.isUppercase }) else { return false }
        if Self.acronymSpellList.contains(word) { return true }
        let lower = word.lowercased()
        let capitalized = lower.prefix(1).uppercased() + lower.dropFirst()
        return lexicon[lower] == nil
            && lexicon[capitalized] == nil
            && g2p?.cachedPhonemes(for: lower) == nil
    }

    // MARK: - Spell-out

    /// Spell a token character-by-character (letters and digits).
    /// Returns nil if any character has no pronunciation.
    func spellOut(_ word: String) -> String? {
        var parts = [String]()
        for ch in word.lowercased() {
            if let ipa = Self.letterPronunciations[ch] ?? Self.digitPronunciations[ch] {
                parts.append(ipa)
            } else if ch == "'" {
                continue
            } else {
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // IPA pronunciations for English letters (used by spellOut)
    private static let letterPronunciations: [Character: String] = [
        "a": "eɪ", "b": "biː", "c": "siː", "d": "diː", "e": "iː",
        "f": "ɛf",  "g": "dʒiː","h": "eɪtʃ","i": "aɪ", "j": "dʒeɪ",
        "k": "keɪ", "l": "ɛl",  "m": "ɛm",  "n": "ɛn",  "o": "oʊ",
        "p": "piː", "q": "kjuː","r": "ɑːr", "s": "ɛs",  "t": "tiː",
        "u": "juː", "v": "viː", "w": "dʌbəljuː","x": "ɛks","y": "waɪ",
        "z": "ziː",
    ]

    // Exact cache pronunciations for digit names (Kokoro notation).
    private static let digitPronunciations: [Character: String] = [
        "0": "zˈɪɹO", "1": "wˈʌn", "2": "tˈu", "3": "θɹˈi", "4": "fˈɔɹ",
        "5": "fˈIv", "6": "sˈɪks", "7": "sˈɛvən", "8": "ˈAt", "9": "nˈIn",
    ]

    // MARK: - Private helpers

    private func pronounceHyphenated(_ word: String) -> String? {
        let parts = word.components(separatedBy: "-").filter { !$0.isEmpty }
        guard parts.count > 1 else { return nil }
        var combined = [String]()
        for part in parts {
            guard let ipa = deterministicLookup(part) ?? spellOut(part) else { return nil }
            combined.append(ipa)
        }
        return combined.joined(separator: " ")
    }

    private func tokenIDs(forIPA ipa: String, unmapped: inout Set<String>) -> [Int32] {
        var ids = [Int32]()
        for scalar in ipa.unicodeScalars {
            let key = String(scalar)
            if let id = vocab[key] {
                ids.append(Int32(id))
            } else if key != " " {
                unmapped.insert(key)
            } else if let space = spaceTokenID() {
                ids.append(space)
            }
        }
        return ids
    }

    private func spaceTokenID() -> Int32? {
        if let id = vocab[" "] { return Int32(id) }
        if !warnedAboutSpaceToken {
            warnedAboutSpaceToken = true
            print("⚠️ Kokoro vocab has no space token — words will concatenate")
        }
        return nil
    }

    /// Lexical-class tags ("VERB"/"NOUN"/"ADJ") aligned with our word split.
    /// NLTagger tokenizes slightly differently, so alignment is a forward
    /// scan with a small look-ahead; unmatched words get nil (→ DEFAULT).
    private static func lexicalClasses(for text: String, alignedWith words: [String]) -> [String?] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var tokens: [(text: String, tag: String?)] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word, scheme: .lexicalClass,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, range in
            tokens.append((String(text[range]).lowercased(), tag?.rawValue))
            return true
        }

        let tagNames: [String: String] = ["Verb": "VERB", "Noun": "NOUN", "Adjective": "ADJ"]
        var result: [String?] = []
        var pointer = 0
        for word in words {
            let lower = word.lowercased()
            var found: String? = nil
            for offset in 0..<3 where pointer + offset < tokens.count {
                if tokens[pointer + offset].text == lower {
                    found = tokens[pointer + offset].tag
                    pointer += offset + 1
                    break
                }
            }
            result.append(found.flatMap { tagNames[$0] })
        }
        return result
    }

    func splitWords(_ text: String) -> [String] {
        // Normalize unicode punctuation before splitting
        let normalized = text
            .replacingOccurrences(of: "\u{2014}", with: " ")  // em dash —
            .replacingOccurrences(of: "\u{2013}", with: " ")  // en dash –
            .replacingOccurrences(of: "\u{2019}", with: "'")  // right single quote '
            .replacingOccurrences(of: "\u{2018}", with: "'")  // left single quote '
            .replacingOccurrences(of: "\u{201C}", with: "\"") // left double quote "
            .replacingOccurrences(of: "\u{201D}", with: "\"") // right double quote "

        let raw = normalized.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let punctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "\"", "'", "(", ")", "[", "]"]
        return raw.compactMap { token -> String? in
            var word = token
            while let first = word.first, punctuation.contains(first) {
                word = String(word.dropFirst())
            }
            while let last = word.last, punctuation.contains(last) {
                word = String(word.dropLast())
            }
            return word.isEmpty ? nil : word
        }
    }
}

// MARK: - Origin provenance

/// Best-effort mapping from normalized words back to the original tokens the
/// normalizer rewrote ("three thirty p m" ← "3:30pm"). The original attaches
/// only to the first word of each replacement group.
private struct OriginQueue {
    private var pending: [(original: String, remaining: [String], isStart: Bool)]

    init(substitutions: [(original: String, replacement: String)]) {
        pending = substitutions.map { sub in
            (sub.original,
             sub.replacement
                .components(separatedBy: .whitespaces)
                .filter { !$0.isEmpty }
                .map { $0.lowercased() },
             true)
        }
        pending.removeAll { $0.remaining.isEmpty }
    }

    mutating func originFor(word: String) -> String? {
        guard !pending.isEmpty,
              pending[0].remaining.first == word.lowercased() else { return nil }
        let original = pending[0].isStart ? pending[0].original : nil
        pending[0].remaining.removeFirst()
        pending[0].isStart = false
        if pending[0].remaining.isEmpty {
            pending.removeFirst()
        }
        return original
    }
}
