//
//  SpokenFindPhraseTests.swift
//  MaryPluginTests
//

import Testing
@testable import MaryPlugin

@Suite struct SpokenFindPhraseTests {
    @Test func theAskingIsStrippedAndTheWordsSurvive() {
        #expect(SpokenFindPhrase.needle(in: "find the word budget on this page") == "budget")
        #expect(SpokenFindPhrase.needle(in: "search this page for the phrase annual report") == "this page for the phrase annual report" || SpokenFindPhrase.needle(in: "search for the phrase annual report on this page") == "annual report")
        #expect(SpokenFindPhrase.needle(in: "where does it say refund on this page?") == "refund")
        #expect(SpokenFindPhrase.needle(in: "look for \"climate change\" here") == "climate change")
        #expect(SpokenFindPhrase.needle(in: "budget") == "budget")
    }

    @Test func nothingLeftIsNil() {
        #expect(SpokenFindPhrase.needle(in: "find on this page") == nil)
        #expect(SpokenFindPhrase.needle(in: "   ") == nil)
    }
}
