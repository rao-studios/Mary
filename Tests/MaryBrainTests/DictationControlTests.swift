//
//  DictationControlTests.swift
//  MaryBrainTests
//
//  THE ONE THING STANDING BETWEEN A NOVEL AND A COMMAND.
//
//  While a dictation session is held, every utterance is typed verbatim unless
//  this classifier says otherwise — so a false positive puts a control phrase
//  into the manuscript's meaning, and a false negative puts the WORDS "Mary
//  stop writing" onto the page and leaves the session open to do it again. The
//  second is worse: it is a trap with no exit, and speech recognition
//  guarantees it will be attempted with a spelling nobody planned for.
//
//  The negative table is therefore real novel prose, not synthetic strings.
//

import Foundation
import Testing
@testable import MaryBrain

@Suite struct DictationControlTests {

    // MARK: - Prose stays prose

    /// RULE 1, whole-and-exact. Every one of these CONTAINS a control phrase
    /// and every one of them is a sentence somebody would dictate.
    @Test(arguments: [
        "she stopped writing",
        "stop writing to her that night",
        "he told them to stop dictating terms",
        "scratch that itch until it bleeds",
        "scratch that she said and turned away",
        "a new paragraph began on the facing page",
        "take this down to the cellar",
        "delete that file she whispered",
        "we are done here he said",
        "mary shut the door behind her",
        "mary stopped writing at midnight",
        "and that is it for the evening",
    ])
    func realProseIsNeverAControl(_ utterance: String) {
        #expect(MaryBrain.dictationControl(in: utterance) == nil, "\(utterance)")
    }

    @Test func anEmptyUtteranceIsNotAControl() {
        #expect(MaryBrain.dictationControl(in: "") == nil)
        #expect(MaryBrain.dictationControl(in: "   ") == nil)
    }

    // MARK: - Addressed controls

    /// RULE 2, and the spellings are the point. The same person saying the
    /// same thing yields all of these on different days; a miss on any one of
    /// them types the words into the manuscript and leaves the session open.
    @Test(arguments: [
        "mary stop writing",
        "Mary, stop writing.",
        "hey mary stop writing",
        "bonny stop writing",
        "stop writing mary",
        "Stop writing, Mary!",
        "okay mary were done",
        "mary thats it",
        "mary stop dictating",
    ])
    func anAddressedStopClosesTheSession(_ utterance: String) {
        #expect(MaryBrain.dictationControl(in: utterance) == .stop, "\(utterance)")
    }

    @Test(arguments: [
        "mary scratch that",
        "Mary, strike that.",
        "scratch that mary",
        "hey mary delete that",
    ])
    func anAddressedScratchRemovesTheLastSpan(_ utterance: String) {
        #expect(MaryBrain.dictationControl(in: utterance) == .scratch, "\(utterance)")
    }

    /// The mirror image, and the reason rule 2 exists: the SAME words without
    /// an address are a line of dialogue.
    @Test func theSameWordsUnaddressedAreProse() {
        #expect(MaryBrain.dictationControl(in: "stop writing") == nil)
        #expect(MaryBrain.dictationControl(in: "scratch that") == nil)
        #expect(MaryBrain.dictationControl(in: "thats it") == nil)
    }

    // MARK: - Structural controls

    /// RULE 3. Bare, because a novelist should not have to say "Mary" every
    /// paragraph, and a misfire costs one break that a scratch undoes.
    @Test func structuralControlsMayBeBare() {
        #expect(MaryBrain.dictationControl(in: "new paragraph") == .newParagraph)
        #expect(MaryBrain.dictationControl(in: "New paragraph.") == .newParagraph)
        #expect(MaryBrain.dictationControl(in: "new line") == .newLine)
        #expect(MaryBrain.dictationControl(in: "mary new paragraph") == .newParagraph)
    }

    // MARK: - The escape hatch

    /// An addressed utterance that is NOT a control is neither typed nor
    /// treated as one: it falls through to the ordinary turn loop for that one
    /// utterance, so the address prefix means one consistent thing.
    @Test func anAddressedQuestionEscapesWithoutClosingTheSession() {
        #expect(MaryBrain.isDictationEscape("mary what time is it"))
        #expect(MaryBrain.isDictationEscape("Mary, how many words so far?"))
        #expect(MaryBrain.dictationControl(in: "mary what time is it") == nil)
    }

    @Test func ordinaryProseIsNotAnEscape() {
        #expect(!MaryBrain.isDictationEscape("she waited by the door"))
        #expect(!MaryBrain.isDictationEscape("okay she said"))
        #expect(!MaryBrain.isDictationEscape("mary"))
    }

    /// A control is a control, not an escape — otherwise "Mary, stop writing"
    /// would fall through to the turn loop and the session would never close.
    @Test func controlsAreNotEscapes() {
        #expect(!MaryBrain.isDictationEscape("mary stop writing"))
        #expect(!MaryBrain.isDictationEscape("mary scratch that"))
    }

    // MARK: - Openers

    @Test(arguments: [
        "take this down",
        "Take this down.",
        "okay mary take this down",
        "start writing",
        "take dictation",
        "im going to dictate",
    ])
    func openersOpen(_ utterance: String) {
        #expect(MaryBrain.dictationOpener(in: utterance), "\(utterance)")
    }

    @Test(arguments: [
        "take this down to the cellar",
        "start writing to her",
        "she started writing",
        "write this down in the ledger he said",
    ])
    func proseThatMerelyContainsAnOpenerDoesNotOpen(_ utterance: String) {
        #expect(!MaryBrain.dictationOpener(in: utterance), "\(utterance)")
    }

    /// No utterance may be both, or opening a session would immediately do
    /// something else as well. The same discipline
    /// `correctionsAndDecisionsDoNotOverlap` applies to its own two gates.
    @Test func openersAndControlsDoNotOverlap() {
        for utterance in [
            "take this down", "start writing", "take dictation",
            "mary stop writing", "new paragraph", "mary scratch that",
        ] {
            let opens = MaryBrain.dictationOpener(in: utterance)
            let controls = MaryBrain.dictationControl(in: utterance) != nil
            #expect(!(opens && controls), "\(utterance) must be one or the other")
        }
    }
}
