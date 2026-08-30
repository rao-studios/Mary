//
//  DictationControlTests.swift
//  MaryBrainTests
//
//  WHAT: Dictation control phrases vs novel prose.
//  OUT:  MaryBrain.dictationControl
//  PIN:  False negative is a trap — real prose must never be a control
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

    /// RULE 2: the same words without an address are a line of dialogue.

    // MARK: - Structural controls

    /// RULE 3. Bare, because a novelist should not have to say "Mary" every
    /// paragraph, and a misfire costs one break that a scratch undoes.
    @Test func structuralControlsMayBeBare() {
        #expect(MaryBrain.dictationControl(in: "new paragraph") == .newParagraph)
        #expect(MaryBrain.dictationControl(in: "New paragraph.") == .newParagraph)
        #expect(MaryBrain.dictationControl(in: "new line") == .newLine)
        #expect(MaryBrain.dictationControl(in: "mary new paragraph") == .newParagraph)
    }
}
