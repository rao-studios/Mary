import Foundation
import Testing
@testable import MaryVoice

/// Tier attribution and the never-silently-dropped invariant, against the
/// real bundled lexicons (skipped politely when LFS assets are absent).
@Suite struct PhonemizerTests {

    private func loadedPhonemizer() async throws -> KokoroPhonemizer {
        let modelsDir = try #require(KokoroAssets.modelsDirectory(),
                                     "Kokoro assets missing — run `git lfs pull`")
        let phonemizer = KokoroPhonemizer()
        try phonemizer.loadVocab(from: modelsDir.appendingPathComponent("vocab_index.json"))
        for name in ["us_gold.json", "gb_gold.json", "us_silver.json", "gb_silver.json"] {
            try phonemizer.loadLexicon(from: modelsDir.appendingPathComponent(name))
        }
        let g2p = KokoroG2P()
        try g2p.loadVocab(from: modelsDir.appendingPathComponent("g2p_vocab.json"))
        try await g2p.loadLexiconCache(
            from: modelsDir.appendingPathComponent("us_lexicon_cache.json"))
        phonemizer.g2p = g2p
        return phonemizer
    }

    private func sources(_ report: PronunciationReport) -> [String: PronunciationSource] {
        Dictionary(report.words.map { ($0.word.lowercased(), $0.source) },
                   uniquingKeysWith: { a, _ in a })
    }

    /// SHE SAYS HER OWN NAME CORRECTLY, AND FROM THE LEXICON.
    ///
    /// This is a regression test for a bug the rename created and no compiler
    /// could see. The custom-override tier held the assistant's name mapped to
    /// hand-tuned IPA; a spelling sweep rewrote the KEY and left the VALUE
    /// alone, so the engine happily answered to "Mary" and pronounced it
    /// "bɑːni" — the old name, out loud, in the one place text search for the
    /// old brand does not look.
    ///
    /// The fix was to delete the override, not to correct it: this name is
    /// ordinary English and the gold lexicon already has it. So the assertion
    /// is on the SOURCE as much as the sound — `custom` here would mean
    /// somebody re-seeded a hand-tuned value that can drift again.
    @Test func herOwnNameComesFromTheLexiconNotAnOverride() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("Mary", maxTokens: 242)
        let word = try #require(report.words.first)

        #expect(word.ipa == "mˈɛɹi", "she is saying \(word.ipa) instead of her name")
        #expect(word.source == .lexicon,
                """
                her name resolved through .\(word.source) — an override here is \
                a value a rename cannot reach, which is how this broke before
                """)
    }

    /// The possessive composes free through the morphology tier, so it cannot
    /// drift away from the base form the way a second hand-seeded entry could.
    @Test func herPossessiveComesFromMorphology() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("Mary's", maxTokens: 242)
        let word = try #require(report.words.first)

        #expect(word.ipa == "mˈɛɹiz")
        #expect(word.source == .morphology)
    }

    /// THE WORDS THAT CONTAIN HER NAME ARE NOT HER NAME. "Summary" and
    /// "primary" are words a person says TO an assistant, and both must reach
    /// the lexicon on their own terms — an override on "mary" that leaked into
    /// substring matching would make every one of these mispronounce.
    @Test func ordinaryWordsContainingHerNameAreUntouched() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize(
            "summary primary rosemary", maxTokens: 242)

        for word in report.words {
            #expect(word.source == .lexicon, "\(word.word) → .\(word.source)")
            #expect(!word.ipa.isEmpty)
        }
        let byWord = Dictionary(report.words.map { ($0.word.lowercased(), $0.ipa) },
                                uniquingKeysWith: { a, _ in a })
        #expect(byWord["summary"] == "sˈʌməɹi")
        #expect(byWord["rosemary"] == "ɹˈOzmˌɛɹi")
    }

    @Test func userNameResolvesThroughCustomLexicon() async throws {
        let phonemizer = try await loadedPhonemizer()
        // The engine's built-in seeds, exercised at the phonemizer level.
        phonemizer.addCustomPronunciation("Ritesh", ipa: "ɹɛtˈɛʃ")
        phonemizer.addCustomPronunciation("Pakala", ipa: "pˈɑkɑlɑ")
        phonemizer.addCustomPronunciation("Rao", ipa: "ɹˈW")

        let (_, report) = await phonemizer.phonemize("Ritesh Pakala Rao", maxTokens: 242)
        let bySource = sources(report)
        #expect(bySource["ritesh"] == .custom)
        #expect(bySource["pakala"] == .custom)
        #expect(bySource["rao"] == .custom)
        // Every notation scalar must map — pins W/ɛ/ʃ/ɑ against the vocab.
        #expect(report.unmappedScalars.isEmpty)
        #expect(report.words.allSatisfy { $0.tokenCount > 0 })

        // Possessives compose from the custom entries via morphology.
        let (_, possessive) = await phonemizer.phonemize("Rao's laptop", maxTokens: 242)
        #expect(sources(possessive)["rao's"] == .morphology)
    }

    @Test func regressionSentenceFullyResolves() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize(
            "Open my applications at 3:30pm. Mary's PDF vs. the NASA docs cost $5.50 in 2026.",
            maxTokens: 500
        )
        // Nothing dropped, nothing accidentally spelled.
        #expect(report.concerns.isEmpty, "\(report.concerns.map(\.word))")

        let bySources = sources(report)
        #expect(bySources["applications"] == .morphology)
        // Lexicon base + morphology suffix. It was `.custom` while her name
        // was hand-seeded; see `herOwnNameComesFromTheLexiconNotAnOverride`.
        #expect(bySources["mary's"] == .morphology)
        #expect(bySources["pdf"] == .spelled)          // intentional acronym
        #expect(bySources["versus"] == .lexicon)       // vs. normalized away
        #expect(bySources["dollars"] == .lexicon)      // $5.50 normalized away
        #expect(report.normalizedText.contains("three thirty p m"))
        #expect(report.normalizedText.contains("twenty twenty-six"))
    }

    @Test func inflectionsResolveThroughMorphology() async throws {
        let phonemizer = try await loadedPhonemizer()
        for word in ["applications", "opened", "mary's"] {
            let (_, report) = await phonemizer.phonemize(word, maxTokens: 200)
            let entry = try #require(report.words.first)
            #expect(entry.source == .morphology || entry.source == .custom,
                    "\(word) → \(entry.source.rawValue)")
            #expect(!entry.ipa.isEmpty)
        }
    }

    @Test func digitsAreNeverDropped() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("meet at 3", maxTokens: 200)
        #expect(report.words.allSatisfy { $0.source != .dropped })
        #expect(report.normalizedText.contains("three"))
    }

    @Test func acronymGateSparesShoutingCaps() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("THIS IS IT", maxTokens: 200)
        // Real words in caps stay words.
        #expect(report.words.allSatisfy { $0.source == .lexicon || $0.source == .cache },
                "\(report.words.map { "\($0.word)→\($0.source.rawValue)" })")
    }

    @Test func curatedAcronymsSpell() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("the PDF and the URL", maxTokens: 200)
        let bySources = sources(report)
        #expect(bySources["pdf"] == .spelled)
        #expect(bySources["url"] == .spelled)
    }

    @Test func caseSensitiveCacheHits() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize("NASA launched", maxTokens: 200)
        let nasa = try #require(report.words.first)
        // NASA resolves as a word (gold lexicon or exact-case cache), never letters.
        #expect(nasa.source == .lexicon || nasa.source == .cache)
        #expect(nasa.ipa.contains("n"))
    }

    @Test func ssmlOverridesStillWin() async throws {
        let phonemizer = try await loadedPhonemizer()
        let (_, report) = await phonemizer.phonemize(
            #"<phoneme alphabet="ipa" ph="mɑːriɛl">Marielle</phoneme> waved"#,
            maxTokens: 200
        )
        #expect(report.words.first?.source == .ssml)
        #expect(report.words.first?.ipa == "mɑːriɛl")
    }

    @Test func nothingSilentlyDropped() async throws {
        let phonemizer = try await loadedPhonemizer()
        let text = "xqzzt 🎉 hello 42 M1"
        let (_, report) = await phonemizer.phonemize(text, maxTokens: 300)
        // Every split word appears in the report, whatever its fate.
        let splitCount = phonemizer.splitWords(
            KokoroTextNormalizer.normalize(text).text).count
        #expect(report.words.count == splitCount)
        // And anything that IS dropped is visibly traced.
        for entry in report.words where entry.ipa.isEmpty {
            #expect(entry.source == .dropped)
        }
    }
}
