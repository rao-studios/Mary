//
//  IntakePlannerTests.swift
//  MaryVoiceTests
//
//  The intake ladder as a row table — `ActionRhythmTests`' shape.
//
//  The rows that matter most are the ones that DON'T admit. Always-on
//  listening is tolerable only because the addressivity gate is conservative:
//  a false negative costs a remembered line, a false positive ACTS.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct IntakePlannerTests {

    private func situation(
        _ text: String,
        finalized: Bool = true,
        silence: TimeInterval = 2,
        selfSpeaking: Bool = false,
        acousticBusy: Bool = false,
        recentlyAddressed: Bool = false
    ) -> IntakePlanner.Situation {
        IntakePlanner.Situation(
            segment: IntakePlanner.Segment(
                text: text, isFinalized: finalized, silenceAfter: silence),
            selfSpeaking: selfSpeaking,
            acousticPathBusy: acousticBusy,
            recentlyAddressed: recentlyAddressed)
    }

    @Test func theIntakeTable() {
        typealias Row = (name: String, situation: IntakePlanner.Situation,
                         expected: IntakePlanner.Verdict)

        let rows: [Row] = [
            // ADDRESSED: the wake word is the whole licence to act.
            ("wake word admits", situation("mary what's on my calendar"),
             .admit("mary what's on my calendar")),
            ("wake word mid-sentence", situation("okay mary open the draft"),
             .admit("okay mary open the draft")),

            // NOT ADDRESSED: remembered, which is never wrong. This is the
            // default and it must stay the default.
            ("office chatter is remembered", situation("we should ship on friday"),
             .remember("we should ship on friday")),

            // HER OWN VOICE, refused before anything else. Without this she
            // transcribes her own TTS and can answer herself.
            ("self speech is refused first",
             situation("mary your two o'clock moved", selfSpeaking: true),
             .hold(.selfSpeech)),

            // VOLATILE spans may still be rewritten — useful for a caption,
            // worthless for a decision.
            ("a volatile span never acts",
             situation("mary delete the file", finalized: false),
             .hold(.volatile)),

            // MID-THOUGHT: the failure the flat 850 ms hangover causes —
            // "add a reminder to… call mom" cut in half.
            ("still talking", situation("mary add a reminder to", silence: 0.3),
             .hold(.midThought)),

            // A fragment is not an utterance.
            ("a single word is a fragment", situation("mary"), .hold(.tooBrief)),
            ("empty", situation("   "), .hold(.empty)),

            // FIRST REFUSAL TO THE ACOUSTIC PATH. It already owns this speech;
            // admitting here too would submit the turn twice.
            ("the acoustic path owns it",
             situation("mary what time is it", acousticBusy: true),
             .remember("mary what time is it")),

            // A live follow-on window needs no wake word.
            ("a follow-on needs no wake word",
             situation("what about tomorrow", recentlyAddressed: true),
             .admit("what about tomorrow")),
        ]

        for row in rows {
            #expect(IntakePlanner.verdict(row.situation) == row.expected, "\(row.name)")
        }
    }

    /// Word-boundary matching, so punctuation counts and a longer word does
    /// not. "summary" admitting a turn would be the worst kind of false
    /// positive — one nobody can explain afterwards.
    @Test func theWakeWordMatchesOnWordBoundaries() {
        #expect(IntakePlanner.namesHer("Mary, what's up"))
        #expect(IntakePlanner.namesHer("hey mary?"))
        #expect(IntakePlanner.namesHer("MARY stop"))
        // THE ORDINARY-ENGLISH TRAP, which this name has and the last one did
        // not: every one of these is a word a person says out loud near a
        // computer, and two of them are words they say to an assistant.
        #expect(!IntakePlanner.namesHer("give me a summary"))
        #expect(!IntakePlanner.namesHer("the primary reason"))
        #expect(!IntakePlanner.namesHer("rosemary and thyme"))
        #expect(!IntakePlanner.namesHer("it is customary"))
        #expect(!IntakePlanner.namesHer(""))
    }

    /// Silence is measured AFTER the words, so a long pause inside a thought
    /// extends it rather than ending it.
    @Test func silenceGatesCompletionIndependentlyOfLength() {
        let brief = situation("mary remind me to call mom", silence: 0.1)
        #expect(IntakePlanner.verdict(brief) == .hold(.midThought))

        let settled = situation("mary remind me to call mom", silence: 5)
        #expect(IntakePlanner.verdict(settled) == .admit("mary remind me to call mom"))
    }
}
