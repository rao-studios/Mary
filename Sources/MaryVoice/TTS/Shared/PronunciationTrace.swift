//
//  PronunciationTrace.swift
//  MaryVoice
//
//  WHAT: Per-word ladder trace for one synthesis call.
//  IN:   KokoroPhonemizer
//  OUT:  probe `pronounce` / engine tap / SpeakerEvent.pronunciation
//

import Foundation

/// The tier that produced a word's pronunciation.
public enum PronunciationSource: String, Sendable, CaseIterable {
    /// Inline SSML `<phoneme ph="…">` override.
    case ssml
    /// addCustomPronunciation override.
    case custom
    /// Merged gold/silver lexicons (exact-case, lowercase, or capitalized key).
    case lexicon
    /// A POS-selected variant from the lexicon's heteronym dicts.
    case lexiconVariant
    /// The 178k pre-computed G2P cache (exact-case or lowercase section).
    case cache
    /// Deterministic inflection rules over a resolved stem.
    case morphology
    /// The neural G2P encoder/decoder.
    case g2p
    /// Intentional letter-by-letter spelling (acronyms) or last-resort spell-out.
    case spelled
    /// Resolved only after stripping unpronounceable scalars.
    case salvaged
    /// Nothing worked — the word is absent from speech (always traced).
    case dropped
}

/// One word's resolution.
public struct WordPronunciation: Sendable {
    public var word: String
    /// The pre-normalization token when the normalizer rewrote it ("3:30pm").
    public var original: String?
    public var source: PronunciationSource
    public var ipa: String
    public var tokenCount: Int
    /// Rule or context: morphology rule ("-s→z"), acronym, POS tag, g2p config.
    public var detail: String?

    public init(
        word: String,
        original: String? = nil,
        source: PronunciationSource,
        ipa: String,
        tokenCount: Int,
        detail: String? = nil
    ) {
        self.word = word
        self.original = original
        self.source = source
        self.ipa = ipa
        self.tokenCount = tokenCount
        self.detail = detail
    }
}

/// The full trace for one synthesis call.
public struct PronunciationReport: Sendable {
    public var text: String
    public var normalizedText: String
    public var words: [WordPronunciation]
    /// IPA scalars that had no vocab id (dropped from token stream).
    public var unmappedScalars: [String]
    /// Final token count including BOS/EOS.
    public var totalTokens: Int

    public init(
        text: String,
        normalizedText: String,
        words: [WordPronunciation] = [],
        unmappedScalars: [String] = [],
        totalTokens: Int = 0
    ) {
        self.text = text
        self.normalizedText = normalizedText
        self.words = words
        self.unmappedScalars = unmappedScalars
        self.totalTokens = totalTokens
    }

    /// Words that didn't resolve through a wanted tier.
    public var concerns: [WordPronunciation] {
        words.filter { $0.source == .dropped || ($0.source == .spelled && $0.detail != "acronym") }
    }

    /// Aligned table for the probe and logs.
    public var table: String {
        let header = ("WORD", "SOURCE", "DETAIL", "IPA", "TOKENS")
        var rows: [(String, String, String, String, String)] = [header]
        for w in words {
            rows.append((
                w.original.map { "\(w.word) (\($0))" } ?? w.word,
                w.source.rawValue,
                w.detail ?? "",
                w.ipa,
                String(w.tokenCount)
            ))
        }
        let widths = (
            rows.map { $0.0.count }.max() ?? 4,
            rows.map { $0.1.count }.max() ?? 6,
            rows.map { $0.2.count }.max() ?? 6,
            rows.map { $0.3.count }.max() ?? 3
        )
        func pad(_ s: String, _ n: Int) -> String {
            s + String(repeating: " ", count: max(0, n - s.count))
        }
        var lines = rows.map { row in
            "\(pad(row.0, widths.0))  \(pad(row.1, widths.1))  \(pad(row.2, widths.2))  \(pad(row.3, widths.3))  \(row.4)"
        }
        lines.insert(String(repeating: "─", count: lines[0].count), at: 1)
        var footer = "total tokens: \(totalTokens)"
        if !unmappedScalars.isEmpty {
            footer += "   unmapped scalars: \(unmappedScalars.joined(separator: " "))"
        }
        if normalizedText != text {
            footer += "\nnormalized: \(normalizedText)"
        }
        lines.append(footer)
        return lines.joined(separator: "\n")
    }
}
