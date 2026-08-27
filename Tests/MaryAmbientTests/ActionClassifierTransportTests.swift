//
//  ActionClassifierTransportTests.swift
//  BonnieAmbientTests
//
//  Music transport has a useful command shorthand ("next track") that does
//  not begin with a verb. The bound is the specification: only a direction
//  paired with a music object acts; temporal and descriptive uses stay in the
//  spoken rhythm.
//

import Testing
@testable import MaryAmbient

@Suite struct ActionClassifierTransportTests {

    @Test func boundedTransportRequestTable() {
        typealias Row = (utterance: String, action: Bool)
        let rows: [Row] = [
            // Bare controller shorthand.
            ("next track", true),
            ("next song", true),
            ("previous track", true),
            ("previous song", true),
            ("next track?", true),

            // The classifier's existing address, filler, and politeness
            // wrappers must expose the same bounded request.
            ("Mary, next song", true),
            ("yeah just next track", true),
            ("please previous song", true),
            ("next track, please", true),
            ("can you next track", true),
            ("could you previous song?", true),
            ("would you please next song?", true),

            // Existing verb-led requests are unchanged.
            ("play the next song", true),
            ("can you play the previous track?", true),

            // `next` and `previous` are not general action verbs. The exact
            // object and exact tail keep calendar/prose fragments and hedged
            // requests out of the silent action rhythm.
            ("next week", false),
            ("previous version", false),
            ("next chapter", false),
            ("the next track is better", false),
            ("what is the next track?", false),
            ("can you tell me the next song?", false),
            ("can you next week?", false),
            ("next track or maybe not", false),
            ("previous song? or wait", false),
        ]

        for row in rows {
            #expect(
                ActionClassifier.isActionCommand(row.utterance) == row.action,
                "\(row.utterance)"
            )
        }
    }
}
