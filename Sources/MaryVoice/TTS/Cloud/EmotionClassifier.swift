//
//  EmotionClassifier.swift
//  MaryVoice
//
//  Picks the emotion a cloud voice should speak a chunk with. Pure and
//  deterministic so every decision is unit-testable. Keyword and punctuation
//  rules run before NLTagger sentiment because sentiment scores on one or two
//  short sentences are noisy — the tagger only breaks ties.
//

import Foundation
import NaturalLanguage

/// The emotion set Mistral's characters render. Raw values are the slug
/// suffixes: "fr_marie" + "_" + rawValue.
public enum MarieEmotion: String, Sendable, Codable, CaseIterable {
    case neutral, sad, happy, excited, curious, angry
}

public enum EmotionClassifier {

    /// Word-boundary cues that read as anger regardless of sentiment polarity.
    private static let angerCues: Set<String> = [
        "furious", "outraged", "outrageous", "unacceptable", "infuriating",
        "hate", "hated", "terrible", "awful", "horrible", "disgusting",
        "angry", "enraged", "livid",
    ]

    /// Cues that read as delight; promoted to excited when the text exclaims.
    private static let excitementCues: Set<String> = [
        "amazing", "incredible", "fantastic", "awesome", "wonderful",
        "brilliant", "spectacular", "thrilled", "excited", "hooray", "wow",
    ]

    private static let sadnessCues: Set<String> = [
        "sad", "sadly", "unfortunately", "sorry", "regret", "tragic",
        "heartbreaking", "grief", "mourning", "lost", "failed", "failure",
    ]

    /// Classify one spoken chunk. `allowed` clamps the result to what the
    /// active character can render; anything outside falls back to neutral.
    public static func classify(
        _ text: String,
        allowed: Set<MarieEmotion> = Set(MarieEmotion.allCases)
    ) -> MarieEmotion {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return clamp(.neutral, to: allowed) }

        let words = wordSet(of: trimmed)
        let exclaims = trimmed.contains("!")
        let sentiment = sentimentScore(of: trimmed)

        // 1. Keyword cues outrank sentiment — "I hate this!" must not read happy.
        if !words.isDisjoint(with: angerCues) {
            return clamp(.angry, to: allowed)
        }
        if !words.isDisjoint(with: excitementCues), exclaims {
            return clamp(.excited, to: allowed)
        }
        if !words.isDisjoint(with: sadnessCues), sentiment <= 0 {
            return clamp(.sad, to: allowed)
        }

        // 2. Punctuation shape. Cued questions were caught above. A trailing
        //    "?" reads curious ONLY when the whole chunk is a question — a
        //    two-sentence chunk of "It failed twice. Should I retry?" used to
        //    render the failure sentence in the curious voice too.
        if trimmed.hasSuffix("?"), !containsNonQuestionSentence(trimmed) {
            return clamp(.curious, to: allowed)
        }
        if trimmed.contains("!!") || hasShoutedWord(trimmed) {
            return clamp(.excited, to: allowed)
        }

        // 3. Sentiment tiebreaker. NLTagger scores mundane short statements
        //    at -0.4…-0.6 ("The file is in the Documents folder." = -0.4), so
        //    only ≤ -0.8 counts as genuinely negative; positives are reliable.
        if sentiment >= 0.6, exclaims { return clamp(.excited, to: allowed) }
        if sentiment >= 0.35 { return clamp(.happy, to: allowed) }
        if sentiment <= -0.8 { return clamp(exclaims ? .angry : .sad, to: allowed) }

        return clamp(.neutral, to: allowed)
    }

    private static func clamp(_ emotion: MarieEmotion, to allowed: Set<MarieEmotion>) -> MarieEmotion {
        allowed.contains(emotion) ? emotion : .neutral
    }

    private static func wordSet(of text: String) -> Set<String> {
        var words: Set<String> = []
        text.lowercased().enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { word, _, _, _ in
            if let word { words.insert(word) }
        }
        // Multi-word cues ("can't wait") don't survive word splitting; catch
        // the common ones directly.
        if text.lowercased().contains("can't wait") { words.insert("thrilled") }
        return words
    }

    /// SHOUTING, not spelling. ALL-CAPS words are how technical vocabulary
    /// is written — "API", "JSON", "HTTP", "TTS" — and a single acronym used
    /// to flip a whole chunk into the excited voice. Shouting is now a claim
    /// about the SENTENCE, not a word: caps words must be a strict MAJORITY
    /// of all words (and at least two), or one caps word with a "!" in the
    /// text. "STOP DOING THAT" (3 of 3) and "WOW!" still read excited; "The
    /// API returns JSON." (2 of 4) stays neutral.
    private static func hasShoutedWord(_ text: String) -> Bool {
        var capsWords = 0
        var totalWords = 0
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.byWords, .localized]
        ) { word, _, _, _ in
            guard let word else { return }
            totalWords += 1
            if word.count >= 3,
               word == word.uppercased(), word != word.lowercased() {
                capsWords += 1
            }
        }
        if capsWords >= 2, capsWords * 2 > totalWords { return true }
        return capsWords >= 1 && text.contains("!")
    }

    /// True when any COMPLETE sentence in the chunk is not a question — the
    /// bound that keeps a trailing "?" from repainting the statements before
    /// it. Sentence terminators before the final "?" are the evidence.
    private static func containsNonQuestionSentence(_ text: String) -> Bool {
        let interior = text.dropLast()   // the trailing "?" itself
        return interior.contains(".") || interior.contains("!")
    }

    /// NLTagger sentiment for the whole chunk, -1…1; 0 when unavailable.
    private static func sentimentScore(of text: String) -> Double {
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .paragraph, scheme: .sentimentScore)
        return tag.flatMap { Double($0.rawValue) } ?? 0
    }
}
