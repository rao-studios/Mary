//
//  DictationControlTests.swift
//  MaryBrainTests
//
//  WHAT: The held session's ONLY rule — is this utterance for Mary or the page?
//  OUT:  MaryBrain.isDictationAddressed
//  PIN:  There is no phrase list to test any more. Stop, scratch and new
//        paragraph are Skills in `writing.mary`; an addressed utterance falls
//        through to routing and finds them. If a control stops working, the
//        fix is a fixture in the package, never a literal here.
//
import Foundation
import Testing
@testable import MaryBrain

@Suite struct DictationControlTests {

    /// PROSE IS THE DEFAULT. Everything unaddressed goes on the page, including
    /// sentences that happen to name the controls — a novelist writing "she
    /// started a new paragraph" must get those words, not a line break.
    @Test(arguments: [
        "she walked to the window and looked out",
        "new paragraph",
        "scratch that",
        "stop writing",
        "that is it",
        "the letter was addressed to mary",
        "okay she said quietly",
        "",
        "   ",
    ])
    func unaddressedSpeechBelongsToThePage(_ utterance: String) {
        #expect(!MaryBrain.isDictationAddressed(utterance), "[\(utterance)]")
    }

    /// ADDRESSED SPEECH GOES BACK TO ROUTING — where the package's dictation
    /// Skills are waiting in the roster.
    @Test(arguments: [
        "mary stop dictating",
        "mary scratch that",
        "mary new paragraph",
        "mary what time is it",
        "hey mary stop",
        "okay mary that is it",
    ])
    func addressedSpeechReturnsToRouting(_ utterance: String) {
        #expect(MaryBrain.isDictationAddressed(utterance), "[\(utterance)]")
    }

    /// HER NAME ALONE IS AN ADDRESS; the soft preambles are not. "Okay, she
    /// said" opens dictated dialogue constantly, so `ok`/`okay`/`hey` only
    /// count in her company.
    @Test func softPreamblesAreNotAnAddressOnTheirOwn() {
        #expect(!MaryBrain.isDictationAddressed("okay so then what"))
        #expect(!MaryBrain.isDictationAddressed("hey there she said"))
        #expect(MaryBrain.isDictationAddressed("hey mary stop dictating"))
    }

    /// KNOWN AMBIGUITY, unchanged from the mode's first version: a dictated
    /// line that OPENS with her name reads as addressed, so "Mary stopped
    /// writing at midnight" goes to routing instead of onto the page. The
    /// trailing case is handled (a name at the end is dialogue); the leading
    /// case cannot be settled positionally — it needs the comma the speech
    /// recognizer did not give us. Pinned so the limit is visible, not lost.
    @Test func aLeadingNameIsReadAsAddressedEvenInProse() {
        #expect(MaryBrain.isDictationAddressed("mary stopped writing at midnight"))
        #expect(!MaryBrain.isDictationAddressed("he turned and looked at mary"))
    }

    /// A BARE NAME IS NOT A COMMAND — it needs something after it, or a
    /// character being addressed in dialogue would end the session.
    @Test func aBareNameIsNotAnAddress() {
        #expect(!MaryBrain.isDictationAddressed("mary"))
        #expect(!MaryBrain.isDictationAddressed("Mary."))
    }
}
