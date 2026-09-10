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

    /// THE BROWSING LANE'S OWN VERBS. "go to" and "search the web for" are the browsing
    /// package's phrases (`BrowsingReachabilityTests` pins that they stay declared), so a
    /// `search_web` dispatched on the confidence lane receives the thing to look for and
    /// not the command wrapped around it — "go to a fred again video on youtube" typed
    /// into an address bar is a worse search than the same sentence without its verb.
    private static let browsingTriggers = AbilityTriggerSchema(
        tokens: ["browser", "click", "page", "result", "search", "site", "video", "web"],
        phrases: [
            "find me", "go to", "look up", "pull up", "search for", "search the web for",
            "take me to", "the first result", "the search box",
        ])

    @Test func aBrowsingRequestKeepsOnlyWhatToLookFor() {
        #expect(SpokenArgumentExtractor.extract(
            "Can you go to a fred again video on youtube",
            triggers: Self.browsingTriggers, applicationAliases: [])
            == "a fred again video on youtube")
        // Longest phrase first: "search the web for" must not lose to "search for".
        #expect(SpokenArgumentExtractor.extract(
            "search the web for alpine touring boots",
            triggers: Self.browsingTriggers, applicationAliases: [])
            == "alpine touring boots")
        #expect(SpokenArgumentExtractor.extract(
            "find me a fireplace video",
            triggers: Self.browsingTriggers, applicationAliases: [])
            == "a fireplace video")
    }

    /// "CAN WE" IS THE SAME REQUEST AS "CAN YOU". Measured live: "Can we watch a fred
    /// again video on youtube" kept its whole preamble because `stripPreamble`'s request
    /// frames only recognized the second person, and the untouched 43-character sentence
    /// is exactly what went on to lose its first sixteen characters to the address-bar
    /// chunk race (`BrowserEngineSeams.addressLanded` now catches that half; this is the
    /// other half — giving the query a fair chance to be short in the first place).
    private static let watchingBrowsingTriggers = AbilityTriggerSchema(
        tokens: Self.browsingTriggers.tokens + ["watch"],
        phrases: Self.browsingTriggers.phrases)

    @Test func aCollaborativeRequestFrameIsStrippedLikeItsSecondPersonForm() {
        #expect(SpokenArgumentExtractor.extract(
            "Can we watch a fred again video on youtube",
            triggers: Self.watchingBrowsingTriggers, applicationAliases: [])
            == "a fred again video on youtube")
        #expect(SpokenArgumentExtractor.extract(
            "Could we watch a fred again video on youtube",
            triggers: Self.watchingBrowsingTriggers, applicationAliases: [])
            == "a fred again video on youtube")
    }

    /// "WATCH" IS ITS OWN LEADING VERB, stripped the same way "play" already is for
    /// media — it never needed a request frame in front of it to be a command.
    @Test func watchIsStrippedAsALeadingVerb() {
        #expect(SpokenArgumentExtractor.extract(
            "watch a fred again video on youtube",
            triggers: Self.watchingBrowsingTriggers, applicationAliases: [])
            == "a fred again video on youtube")
    }
}
