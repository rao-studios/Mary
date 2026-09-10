//
//  DeterministicTierTests.swift
//  MaryBrainTests
//
//  WHAT: The tier's sets are FROZEN and whole-utterance; the reading composes.
//  PIN:  These tests exist to make widening a set a deliberate, visible act.
//        Nothing here should ever be relaxed to make a paraphrase pass — a
//        paraphrase belongs to `TurnTriage`, not to a closed set.
//
import Foundation
import Testing
@testable import MaryBrain

@Suite struct DeterministicTierTests {

    // MARK: - Whole-utterance, exact

    @Test(arguments: [
        "yes", "Yes.", "yes please", "okay, do it", "go ahead", "sure go ahead",
    ])
    func affirmativesRead(_ text: String) {
        #expect(DeterministicTier.decision(in: text) == true, "[\(text)]")
    }

    @Test(arguments: [
        "no", "Nope.", "cancel", "never mind", "no thanks", "stop",
    ])
    func negativesRead(_ text: String) {
        #expect(DeterministicTier.decision(in: text) == false, "[\(text)]")
    }

    /// THE POINT OF THE TIER. An answer that says anything more carries its own
    /// verb and belongs to the model — a partial affirmative must NOT read as
    /// a bare one, or "yes, tighten it" would silently confirm a parked action.
    @Test(arguments: [
        "yes, tighten it", "yes but change the title", "no, use the other one",
        "sure, what about tomorrow", "stop the music", "okay so what next",
        "", "   ",
    ])
    func anythingMoreAbstains(_ text: String) {
        #expect(DeterministicTier.decision(in: text) == nil, "[\(text)]")
    }

    // MARK: - The tier's boundary

    /// THE TRIM, PINNED. Corrections name documents and dictation controls
    /// name a writing mode: both have a subject, so a corpus can own them and
    /// neither belongs to the tier. This test fails the moment something with
    /// a domain is added back.
    @Test func lanePhrasesAreNotTheTiersBusiness() {
        for text in [
            "no the other one", "the other note", "wrong document",
            "stop dictating", "new paragraph", "scratch that",
            "take this down", "play some jazz", "tighten this up",
        ] {
            #expect(
                DeterministicTier.decision(in: text) == nil,
                "[\(text)] names a domain — it belongs to a corpus, not the tier")
        }
    }

    /// A correction is still exact, but it is no longer tier protocol — and it
    /// must never collide with a decision, or its meaning would depend on
    /// which branch of the turn body asked first.
    @Test func correctionsAndDecisionsAreDisjoint() {
        for text in [
            "no the other one", "the other one", "not that one", "wrong note",
            "i meant the other note", "no not that one", "the other document",
        ] {
            #expect(ReferenceCorrectionGrammar.isCorrection(text), "[\(text)]")
            #expect(
                DeterministicTier.decision(in: text) == nil,
                "[\(text)] is a correction, so it must not also be a decision")
        }
        for text in ["no", "yes", "cancel", "okay"] {
            #expect(
                !ReferenceCorrectionGrammar.isCorrection(text),
                "[\(text)] is a decision, not a correction")
        }
    }
}
