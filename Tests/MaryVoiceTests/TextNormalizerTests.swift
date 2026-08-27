import Foundation
import Testing
@testable import MaryVoice

@Suite struct TextNormalizerTests {

    private func normalized(_ text: String) -> String {
        KokoroTextNormalizer.normalize(text).text
    }

    @Test func cardinals() {
        #expect(KokoroTextNormalizer.cardinal(0) == "zero")
        #expect(KokoroTextNormalizer.cardinal(13) == "thirteen")
        #expect(KokoroTextNormalizer.cardinal(105) == "one hundred five")
        #expect(KokoroTextNormalizer.cardinal(1234) == "one thousand two hundred thirty-four")
        #expect(KokoroTextNormalizer.cardinal(1_234_567)
                == "one million two hundred thirty-four thousand five hundred sixty-seven")
        #expect(KokoroTextNormalizer.cardinal(1_000_000_000_000) == "one trillion")
    }

    @Test func ordinals() {
        #expect(KokoroTextNormalizer.ordinal(1) == "first")
        #expect(KokoroTextNormalizer.ordinal(2) == "second")
        #expect(KokoroTextNormalizer.ordinal(3) == "third")
        #expect(KokoroTextNormalizer.ordinal(11) == "eleventh")
        #expect(KokoroTextNormalizer.ordinal(21) == "twenty-first")
        #expect(KokoroTextNormalizer.ordinal(30) == "thirtieth")
        #expect(normalized("the 3rd time") == "the third time")
    }

    @Test func years() {
        #expect(KokoroTextNormalizer.yearWords(1999) == "nineteen ninety-nine")
        #expect(KokoroTextNormalizer.yearWords(2026) == "twenty twenty-six")
        #expect(KokoroTextNormalizer.yearWords(2007) == "two thousand seven")
        #expect(KokoroTextNormalizer.yearWords(1900) == "nineteen hundred")
        #expect(KokoroTextNormalizer.yearWords(2000) == "two thousand")
        #expect(KokoroTextNormalizer.yearWords(1905) == "nineteen oh five")
        #expect(normalized("back in 1999") == "back in nineteen ninety-nine")
    }

    @Test func decimalsAndPercent() {
        #expect(normalized("3.14 is pi") == "three point one four is pi")
        #expect(normalized("42% done") == "forty-two percent done")
        #expect(normalized("3.5% rate") == "three point five percent rate")
    }

    @Test func currency() {
        #expect(normalized("$5") == "five dollars")
        #expect(normalized("$1") == "one dollar")
        #expect(normalized("$5.50") == "five dollars and fifty cents")
        #expect(normalized("$1,200") == "one thousand two hundred dollars")
    }

    @Test func times() {
        #expect(normalized("at 3:30pm") == "at three thirty p m")
        #expect(normalized("at 12:00") == "at twelve o'clock")
        #expect(normalized("at 9:05 AM") == "at nine oh five a m")
        #expect(normalized("at 3pm") == "at three p m")
        #expect(normalized("13:30 departure") == "thirteen thirty departure")
    }

    @Test func phoneNumbers() {
        #expect(normalized("call 415-555-1212")
                == "call four one five five five five one two one two")
    }

    @Test func abbreviations() {
        #expect(normalized("Dr. Smith arrived") == "Doctor Smith arrived")
        #expect(normalized("on Main Dr. today") == "on Main Drive today")
        #expect(normalized("Mr. Jones") == "Mister Jones")
        #expect(normalized("A vs. B") == "A versus B")
        #expect(normalized("fruit, e.g. apples") == "fruit, for example apples")
        #expect(normalized("St. Louis") == "Saint Louis")
    }

    @Test func units() {
        #expect(normalized("5 km away") == "five kilometers away")
        #expect(normalized("16 GB of RAM") == "sixteen gigabytes of RAM")
        // "min" without a preceding number word stays untouched.
        #expect(normalized("the min value") == "the min value")
    }

    @Test func idempotence() {
        let samples = [
            "Open my applications at 3:30pm. Mary's PDF vs. the NASA docs cost $5.50 in 2026.",
            "call 415-555-1212 about the 3rd meeting at 9:05 AM for $1,200",
        ]
        for sample in samples {
            let once = normalized(sample)
            #expect(normalized(once) == once)
        }
    }
}
