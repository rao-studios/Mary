//
//  SpokenTitleMatcherTests.swift
//  MaryPluginTests
//
//  WHAT: Trailing "…in Apple Music" app context is stripped before matching,
//        so it cannot tie against a candidate whose own title is "Music".
//  OUT:  SpokenTitleMatcher.resolve
//

import Testing
@testable import MaryPlugin

@Suite struct SpokenTitleMatcherTests {

    @Test func trailingAppContextDoesNotShadowASimilarlyNamedCandidate() {
        let candidates = ["RAO", "Music"]
        for utterance in [
            "Play the RAO playlist in Apple Music",
            "Can you play the RAO playlist in Apple Music",
            "Play the RAO playlist on Apple Music",
        ] {
            #expect(
                SpokenTitleMatcher.resolve(utterance, in: candidates) == .match("RAO"),
                "\"\(utterance)\" did not resolve uniquely to RAO")
        }
    }

    @Test func trailingAppContextAloneIsNotStrippedToNothing() {
        // "in apple music" is the WHOLE request with nothing else to strip
        // down to — the guard must leave the tokens intact rather than
        // emptying the query, so resolution still runs (and honestly finds
        // nothing to play, with no candidate named after the app itself).
        #expect(
            SpokenTitleMatcher.resolve("in apple music", in: ["RAO"]) == .none(closest: []))
    }

    // MARK: - Commit to best guess (SpokenTitleCommitContext only)

    @Test func aClearBestOverlapCommitsUnderTheTaskLocal() {
        let candidates = ["RAO Extended Mix", "Workout"]
        for query in ["rao extended session", "rao mix please"] {
            #expect(
                SpokenTitleMatcher.resolve(query, in: candidates) == .none(
                    closest: ["RAO Extended Mix"]),
                "\"\(query)\" without commit context must still refuse")
            let committed = SpokenTitleCommitContext.$allowed.withValue(true) {
                SpokenTitleMatcher.resolve(query, in: candidates)
            }
            #expect(
                committed == .guessed("RAO Extended Mix"),
                "\"\(query)\" under commit context should guess the one clear candidate")
        }
    }

    /// A genuine top-score TIE is still refused even under commit context —
    /// "never guess into a coin flip" holds regardless of who is asking.
    @Test func aGenuineTieStillRefusesUnderCommitContext() {
        let candidates = ["RAO Morning", "RAO Evening"]
        let query = "rao afternoon"
        let committed = SpokenTitleCommitContext.$allowed.withValue(true) {
            SpokenTitleMatcher.resolve(query, in: candidates)
        }
        switch committed {
        case .none(let closest):
            #expect(Set(closest) == Set(candidates))
        default:
            Issue.record("expected a refusal on a genuine tie, got \(committed)")
        }
    }

    /// Insufficient overlap (below the commit floor) still refuses under
    /// commit context — commit only promotes a CLEAR best guess, not any
    /// guess.
    @Test func insufficientOverlapStillRefusesUnderCommitContext() {
        let candidates = ["Friday Commute Mix", "Workout"]
        let query = "the friday one"
        #expect(SpokenTitleMatcher.resolve(query, in: candidates) == .none(
            closest: ["Friday Commute Mix"]))
        let committed = SpokenTitleCommitContext.$allowed.withValue(true) {
            SpokenTitleMatcher.resolve(query, in: candidates)
        }
        #expect(committed == .none(closest: ["Friday Commute Mix"]))
    }

    @Test func aRealTitleContainingAppleMusicWordsStillResolves() {
        // The trailing phrase must anchor at the END of the utterance — a
        // playlist actually named "Apple Music Essentials" is untouched
        // because "apple music" here is not a trailing run.
        #expect(
            SpokenTitleMatcher.resolve(
                "play apple music essentials", in: ["Apple Music Essentials", "RAO"])
                == .match("Apple Music Essentials"))
    }
}
