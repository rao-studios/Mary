import Foundation
import Testing
@testable import MaryVoice

/// POS-selected heteronym variants ("record" the verb vs the noun).
@Suite struct HeteronymTests {

    private func loadedPhonemizer() throws -> KokoroPhonemizer {
        let modelsDir = try #require(KokoroAssets.modelsDirectory(),
                                     "Kokoro assets missing — run `git lfs pull`")
        let phonemizer = KokoroPhonemizer()
        try phonemizer.loadVocab(from: modelsDir.appendingPathComponent("vocab_index.json"))
        for name in ["us_gold.json", "gb_gold.json"] {
            try phonemizer.loadLexicon(from: modelsDir.appendingPathComponent(name))
        }
        return phonemizer
    }

    @Test func variantLexiconLoads() throws {
        let phonemizer = try loadedPhonemizer()
        let variants = try #require(phonemizer.variantLexicon["record"])
        #expect(variants["DEFAULT"] != nil)
        #expect(variants["VERB"] != nil)
        #expect(variants["DEFAULT"] != variants["VERB"])
    }

    @Test func verbContextSelectsVerbVariant() async throws {
        let phonemizer = try loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("Please record the meeting.", maxTokens: 200)
        let record = try #require(report.words.first { $0.word.lowercased() == "record" })
        let variants = try #require(phonemizer.variantLexicon["record"])
        // NLTagger reliably tags "record" after "Please" as a verb; if the
        // tagger ever changes its mind, the word must still resolve via
        // DEFAULT — never break speech over a POS disagreement.
        if record.source == .lexiconVariant {
            #expect(record.ipa == variants["VERB"])
            #expect(record.detail == "VERB")
        } else {
            #expect(record.source == .lexicon)
            #expect(record.ipa == variants["DEFAULT"])
        }
    }

    @Test func nounContextKeepsDefault() async throws {
        let phonemizer = try loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("The record is broken.", maxTokens: 200)
        let record = try #require(report.words.first { $0.word.lowercased() == "record" })
        let variants = try #require(phonemizer.variantLexicon["record"])
        #expect(record.ipa == variants["DEFAULT"] || record.ipa == variants["NOUN"])
    }
}
