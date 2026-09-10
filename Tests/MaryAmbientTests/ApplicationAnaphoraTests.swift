//
//  ApplicationAnaphoraTests.swift
//  MaryAmbientTests
//
//  WHAT: Which follow-ups may inherit the application Mary just resolved.
//  OUT:  AmbientRanker.referencesApplicationAnaphorically
//  PIN:  THIS IS A VOCABULARY, AND A VOCABULARY IS WHERE THE BUGS LIVE. The
//        function has now been wrong twice in the same way — once holding only
//        the CREATION verbs, once holding only those plus the TRANSFORM family.
//        The negative cases below matter as much as the positive ones: widening
//        a lexical gate is how "every turn is about the last app" starts.
//

import Testing
@testable import MaryAmbient

@Suite struct ApplicationAnaphoraTests {

    // MARK: - The composition family

    /// THE REPORTED TURN. "Open a new TextEdit window" then this — the plainest
    /// continuation there is, and it inherited nothing because `write` was not
    /// a word this function knew.
    @Test func composingIntoItContinuesTheApplication() {
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "can you write a poem in that window"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "type this into it"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "draft something in there"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "jot that down here"))
    }

    /// A LEADING ACKNOWLEDGEMENT IS THE SHAPE OF A CONTINUATION, not a verb.
    /// The strip took joiners only, so "yeah" reached the verb test and failed
    /// it — the request frame behind it was never even consulted.
    @Test func aLeadingAcknowledgementIsStripped() {
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "yeah can you write a poem in that window"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "ok now put a heading in it"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "sure, add a paragraph there"))
    }

    // MARK: - What must still NOT inherit

    /// NO ANAPHOR, NO INHERITANCE. A fresh request naming nothing is not a
    /// continuation of anything, however composey its verb.
    @Test func aBareComposeRequestInheritsNothing() {
        #expect(!AmbientRanker.referencesApplicationAnaphorically(
            "can you write a poem"))
        #expect(!AmbientRanker.referencesApplicationAnaphorically(
            "write me a short story about fog"))
    }

    /// The verb still has to be one, and the acknowledgement strip must not
    /// have turned a bare agreement into a command.
    @Test func agreementAloneIsNotACommand() {
        #expect(!AmbientRanker.referencesApplicationAnaphorically("yeah"))
        #expect(!AmbientRanker.referencesApplicationAnaphorically("ok sure"))
        #expect(!AmbientRanker.referencesApplicationAnaphorically(
            "yeah that one was good"))
    }

    /// The families that were already here keep working — the point of adding
    /// a third was that all three describe one relationship.
    @Test func theOlderFamiliesAreUnchanged() {
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "can you add a draft here"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "tighten that up in there"))
        #expect(AmbientRanker.referencesApplicationAnaphorically(
            "in that app, make it bigger"))
    }
}
