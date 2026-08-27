//
//  WakePlannerTests.swift
//  MaryVoiceTests
//
//  The wake and stop-listening matchers as row tables — `IntakePlannerTests`'
//  shape. The rows that matter most are the ones that DON'T wake: a false
//  positive here opens the microphone and ACTS, so the positional gate is the
//  behavior under test.
//

import Foundation
import Testing
@testable import MaryVoice

@Suite struct WakePlannerTests {

    @Test func theWakeTable() {
        typealias Row = (name: String, text: String, expected: WakePlanner.Wake?)

        let rows: [Row] = [
            // BARE WAKES — greet and listen.
            ("the name alone", "Mary", .bare),
            ("greeting prefix", "Hey Mary", .bare),
            ("punctuated", "hey mary?", .bare),
            ("okay-comma form", "Okay, Mary.", .bare),
            ("hi form", "Hi Mary", .bare),
            ("leading recognizer punctuation", "— Mary", .bare),

            // HOMOPHONES — STT spells her name four ways.
            ("bonny", "bonny", .bare),
            ("bonni", "Hey Bonni", .bare),
            ("bonne", "bonne", .bare),

            // WAKE + REQUEST — the remainder rides along, casing and
            // punctuation preserved.
            ("request after comma", "Hey Mary, what's the weather?",
             .request("what's the weather?")),
            ("request unpunctuated", "Mary open my email",
             .request("open my email")),
            ("request after a dash", "Hey Mary — turn it down",
             .request("turn it down")),
            ("preamble stack", "ok hey mary play some jazz",
             .request("play some jazz")),

            // NOT WAKES — the name must LEAD. Standby false positives act,
            // so every one of these must stay nil.
            ("embedded word", "rosemary", nil),
            ("ordinary English", "give me a summary", nil),
            ("ordinary English", "the primary reason", nil),
            ("mentioned, not addressed", "tell mary I said hi", nil),
            ("mid-sentence mention", "I told Mary about it", nil),
            ("article prefix", "the mary situation", nil),
            ("empty", "", nil),
            ("ordinary sentence", "so what should we do about friday", nil),
        ]

        for row in rows {
            #expect(WakePlanner.wake(in: row.text) == row.expected, "\(row.name)")
        }
    }

    @Test func theEarlyAbortTable() {
        typealias Row = (name: String, partial: String, expected: Bool)

        let rows: [Row] = [
            // STILL AMBIGUOUS — keep transcribing.
            ("empty partial", "", true),
            ("preamble only", "hey", true),
            ("the name is forming", "hey bon", true),
            ("a greeting word is forming", "he", true),
            ("the name landed", "mary", true),
            ("wake with request underway", "hey mary what", true),

            // RULED OUT — cancel transcription now; the rest of this
            // utterance is none of her business.
            ("conversation", "so I was saying", false),
            ("another assistant", "hey siri play", false),
            ("ordinary opener mid-word", "hello there we", false),
            ("mention can't lead", "tell mary", false),
        ]

        for row in rows {
            #expect(WakePlanner.couldStillWake(partial: row.partial) == row.expected, "\(row.name)")
        }
    }

    @Test func theStopListeningTable() {
        typealias Row = (name: String, text: String, expected: Bool)

        let rows: [Row] = [
            // THE COMMAND, whole and exact after address stripping.
            ("bare command", "stop listening", true),
            ("punctuated", "Stop listening.", true),
            ("addressed", "Mary, stop listening", true),
            ("okay prefix", "okay stop listening", true),
            ("polite", "please stop listening", true),
            ("fully dressed", "mary please stop listening now", true),
            ("quit variant", "hey mary quit listening", true),

            // PROSE, NOT A COMMAND. Bare "stop" stays with the routine-cancel
            // vocabulary downstream; sentences ABOUT listening stay turns.
            ("bare stop is not ours", "stop", false),
            ("addressed bare stop is not ours", "mary stop", false),
            ("stop something else", "stop the music", false),
            ("listening to something", "stop listening to them", false),
            ("opposite", "keep listening", false),
            ("empty", "", false),
        ]

        for row in rows {
            #expect(WakePlanner.isStopListening(row.text) == row.expected, "\(row.name)")
        }
    }
}
