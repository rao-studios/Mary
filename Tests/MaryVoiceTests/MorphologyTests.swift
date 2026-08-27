import Foundation
import Testing
@testable import MaryVoice

/// Suffix rules against the exact Kokoro-notation strings observed in the
/// shipped G2P cache. A fixture dictionary stands in for the lexicon.
@Suite struct MorphologyTests {

    private let fixture: [String: String] = [
        "cat": "kˈæt",
        "dog": "dˈɔɡ",
        "box": "bˈɑks",
        "wish": "wˈɪʃ",
        "computer": "kəmpjˈuɾəɹ",
        "application": "ˌæpləkˈAʃən",
        "walk": "wˈɔk",
        "play": "plˈA",
        "need": "nˈid",
        "open": "ˈOpᵊn",
        "run": "ɹˈʌn",
        "make": "mˈAk",
        "big": "bˈɪɡ",
        "fast": "fˈæst",
        "quick": "kwˈɪk",
        "happy": "hˈæpi",
        "mary": "bɑːni",
        "kind": "kˈInd",
        "grateful": "ɡɹˈAtfəl",
        "book": "bˈʊk",
        "shelf": "ʃˈɛlf",
        "pepper": "pˈɛpəɹ",
        "binge": "bˈɪnʤ",
    ]

    private func pronounce(_ word: String) -> (ipa: String, rule: String)? {
        KokoroMorphology.pronounce(word) { fixture[$0] }
    }

    @Test func pluralVoicing() {
        #expect(pronounce("cats")?.ipa == "kˈæts")            // voiceless → s
        #expect(pronounce("dogs")?.ipa == "dˈɔɡz")            // voiced → z
        #expect(pronounce("boxes")?.ipa == "bˈɑksᵻz")         // sibilant → ᵻz
        #expect(pronounce("wishes")?.ipa == "wˈɪʃᵻz")
        #expect(pronounce("computers")?.ipa == "kəmpjˈuɾəɹz")
        #expect(pronounce("applications")?.ipa == "ˌæpləkˈAʃənz")
    }

    @Test func possessives() {
        #expect(pronounce("application's")?.ipa == "ˌæpləkˈAʃənz")
        #expect(pronounce("mary's")?.ipa == "bɑːniz")       // custom-lexicon stem
        #expect(pronounce("cats'")?.ipa == "kˈæts")
    }

    @Test func pastTenseVoicing() {
        #expect(pronounce("walked")?.ipa == "wˈɔkt")          // voiceless → t
        #expect(pronounce("played")?.ipa == "plˈAd")          // voiced → d
        #expect(pronounce("needed")?.ipa == "nˈidᵻd")         // t/d → ᵻd
        #expect(pronounce("opened")?.ipa == "ˈOpᵊnd")
        #expect(pronounce("peppered")?.ipa == "pˈɛpəɹd")
    }

    @Test func ingWithStemRecovery() {
        #expect(pronounce("walking")?.ipa == "wˈɔkɪŋ")
        #expect(pronounce("running")?.ipa == "ɹˈʌnɪŋ")        // de-doubled stem
        #expect(pronounce("making")?.ipa == "mˈAkɪŋ")         // e-restored stem
        #expect(pronounce("bingeing")?.ipa == "bˈɪnʤɪŋ")
    }

    @Test func comparativesAndAdverbs() {
        #expect(pronounce("bigger")?.ipa == "bˈɪɡəɹ")         // de-doubled
        #expect(pronounce("fastest")?.ipa == "fˈæstɪst")
        #expect(pronounce("quickly")?.ipa == "kwˈɪkli")
        #expect(pronounce("happily")?.ipa == "hˈæpəli")       // y-stem i→əli
        #expect(pronounce("gratefully")?.ipa == "ɡɹˈAtfəli")  // final l → i
    }

    @Test func unPrefix() {
        #expect(pronounce("unkind")?.ipa == "ʌŋkˈInd")        // velar assimilation
        #expect(pronounce("unhappy")?.ipa == "ʌnhˈæpi")
    }

    @Test func compounds() {
        #expect(pronounce("bookshelf")?.ipa == "bˈʊk ʃˈɛlf")
    }

    @Test func guards() {
        #expect(pronounce("as") == nil)                       // too short
        #expect(pronounce("xyzzys") == nil)                   // unresolvable stem
    }
}
