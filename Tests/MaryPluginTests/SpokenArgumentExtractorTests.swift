//
//  SpokenArgumentExtractorTests.swift
//  MaryPluginTests
//
//  WHAT: The confidence-dispatch shortcut's one required string parameter
//        gets the EXTRACTED span, never the whole spoken sentence.
//  OUT:  SpokenArgumentExtractor.extract
//

import Testing
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct SpokenArgumentExtractorTests {

    private static let multimediaTriggers = AbilityTriggerSchema(
        tokens: ["play", "pause", "shuffle", "playlist", "playlists", "music"],
        phrases: ["put on my", "shuffle my"])

    private static let appleMusicAliases: Set<String> = ["apple music", "the music app", "itunes"]

    /// Both screenshot utterances land on the same clean payload, matching
    /// the traced design exactly.
    @Test func bothScreenshotUtterancesExtractTheSamePlaylistSpan() {
        let openForm = SpokenArgumentExtractor.extract(
            "Can you open Apple Music and play the RAO playlist",
            triggers: Self.multimediaTriggers, applicationAliases: Self.appleMusicAliases)
        #expect(openForm == "the RAO playlist")

        let trailingForm = SpokenArgumentExtractor.extract(
            "Can you play the RAO playlist in Apple Music",
            triggers: Self.multimediaTriggers, applicationAliases: Self.appleMusicAliases)
        #expect(trailingForm == "the RAO playlist")
    }

    /// The leading command verb comes from the SKILL'S OWN package data
    /// (`triggers.tokens`/`.phrases`), not a hardcoded media-only list —
    /// a reminder-shaped utterance degrades gracefully through the same
    /// mechanism with reminders' own vocabulary.
    @Test func reminderShapedUtteranceUsesItsOwnPackageVocabulary() {
        let remindersTriggers = AbilityTriggerSchema(
            tokens: ["reminders", "remind", "reminder"],
            phrases: ["remind me to", "add a reminder"])
        let result = SpokenArgumentExtractor.extract(
            "Can you remind me to call mom",
            triggers: remindersTriggers, applicationAliases: [])
        #expect(result == "call mom")
    }

    /// Trailing app context generalizes to ANY resolved application's own
    /// aliases — not a hardcoded "apple music" list, the exact weakness
    /// this extractor replaces.
    @Test func trailingContextGeneralizesToAnyApplicationsAliases() {
        let spotifyAliases: Set<String> = ["spotify"]
        let result = SpokenArgumentExtractor.extract(
            "Play my workout mix on Spotify",
            triggers: Self.multimediaTriggers, applicationAliases: spotifyAliases)
        #expect(result == "my workout mix")
    }

    /// Nothing to extract but grammar and a verb — degrades to the least-
    /// stripped non-empty stage rather than returning "".
    @Test func neverReturnsEmptyEvenWhenNothingButGrammarWasSaid() {
        let result = SpokenArgumentExtractor.extract(
            "Can you play",
            triggers: Self.multimediaTriggers, applicationAliases: Self.appleMusicAliases)
        #expect(!result.isEmpty)
    }

    /// A leading open-clause with NO trailing "and" is not a command frame —
    /// left untouched by that stage, so a title that happens to start with
    /// "open" (a hypothetical playlist literally named that) is not eaten.
    @Test func aLeadingOpenWordWithNoAndClauseIsNotStripped() {
        let result = SpokenArgumentExtractor.extract(
            "play open mic night",
            triggers: Self.multimediaTriggers, applicationAliases: Self.appleMusicAliases)
        #expect(result == "open mic night")
    }
}
