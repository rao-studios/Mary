//
//  SpokenEnumExtractorTests.swift
//  MaryPluginTests
//
//  WHAT: Which declared enum value a sentence names — and, far more often,
//        that it names none.
//  PIN:  THE REFUSALS ARE THE POINT. This is what lets a structured argument
//        skip the model entirely, so every case below that expects nil is
//        load-bearing safety, not an edge case.
//

import Foundation
import Testing
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct SpokenEnumExtractorTests {

    /// `multimedia.control-playback`'s real shape, as the package declares it.
    private static func transport() -> ModelParameterSchema {
        ModelParameterSchema(
            name: "action",
            type: "string",
            summary: "What to do.",
            required: true,
            enumValues: ["play", "pause", "next", "previous", "louder", "quieter", "mute"],
            spokenValues: [
                "pause": ["pause", "hold"],
                "play": ["play", "resume", "continue", "unpause", "start"],
                "next": ["next", "skip", "next song", "next track", "skip this", "skip song", "skip track"],
                "previous": ["previous", "back", "go back", "last song", "previous track", "previous song"],
                "louder": ["louder", "turn it up", "turn the volume up", "volume up", "turn up"],
                "quieter": ["quieter", "softer", "turn it down", "turn the volume down", "volume down", "turn down"],
                "mute": ["mute", "silence", "unmute"],
            ])
    }

    private static func direction() -> ModelParameterSchema {
        ModelParameterSchema(
            name: "direction",
            type: "string",
            summary: "Which way.",
            required: false,
            enumValues: ["down", "up"],
            spokenValues: ["down": ["down", "scroll down"], "up": ["up", "scroll up", "back up"]])
    }

    // MARK: - What it answers

    /// THE REPORTED SENTENCE. The value is the word, said out loud, and the
    /// polite frame in front of it is not part of the answer.
    @Test(arguments: [
        ("can you pause the music", "pause"),
        ("Can you pause the music?", "pause"),
        ("pause the song", "pause"),
        ("could you skip this song", "next"),
        ("go back to the last one", "previous"),
        ("turn it down a bit", "quieter"),
        ("turn the volume up", "louder"),
        ("mute it", "mute"),
    ])
    func aSpokenValueIsFound(_ utterance: String, _ expected: String) {
        #expect(
            SpokenEnumExtractor.value(for: Self.transport(), in: utterance)?.value == expected,
            "[\(utterance)]")
    }

    /// THE BUG THIS CLOSES ON THE OPTIONAL SIDE: "scroll up" won its skill on
    /// the corpus, dispatched with no arguments at all, and the binding's own
    /// default scrolled DOWN — the opposite of what was asked, reported as a
    /// success.
    @Test func anOptionalDirectionIsFound() {
        #expect(SpokenEnumExtractor.value(for: Self.direction(), in: "scroll up")?.value == "up")
        #expect(SpokenEnumExtractor.value(for: Self.direction(), in: "scroll down")?.value == "down")
    }

    /// A LONGER PHRASE IS NOT TWO SHORTER ONES. "turn it down" must not also
    /// count as a bare "down" for some other value, and "go back" must not
    /// count twice.
    @Test func theLongestPhraseConsumesItsWords() {
        let match = SpokenEnumExtractor.value(for: Self.transport(), in: "turn it down")
        #expect(match?.value == "quieter")
        #expect(match?.spokenAs == "turn it down")
    }

    // MARK: - What it refuses

    /// TWO VALUES IS A SENTENCE FOR THE MODEL. "pause it and then skip to the
    /// next one" is two acts; dispatching the first silently drops the second.
    @Test func twoValuesRefuse() {
        #expect(SpokenEnumExtractor.value(
            for: Self.transport(), in: "pause it and then skip to the next one") == nil)
    }

    /// Nothing named is nothing to say — never a default.
    @Test(arguments: [
        "what is playing",
        "play the RAO playlist",  // "play" IS named — see the note below.
        "",
        "do the thing",
    ])
    func silenceOrNoiseIsNotAValue(_ utterance: String) {
        let match = SpokenEnumExtractor.value(for: Self.transport(), in: utterance)
        // "play the RAO playlist" genuinely says "play", and this extractor is
        // asked only about a skill the roster already picked — deciding WHICH
        // skill is not its job. The other three name nothing.
        if utterance.contains("play the RAO") {
            #expect(match?.value == "play")
        } else {
            #expect(match == nil, "[\(utterance)]")
        }
    }

    /// A parameter with no enum has nothing to answer with.
    @Test func aPlainStringIsNotAnEnum() {
        let plain = ModelParameterSchema(
            name: "target", type: "string", summary: "", required: true)
        #expect(SpokenEnumExtractor.value(for: plain, in: "pause the music") == nil)
    }

    // MARK: - Repair at the chokepoint

    /// A VALUE ALREADY IN THE ENUM IS WHAT THE CALLER MEANT. The model reads
    /// more of the turn than one utterance line does.
    @Test func aValidValueIsNeverOverridden() {
        let repaired = SpokenEnumExtractor.repaired(
            ["action": "next"], parameters: [Self.transport()], utterance: "pause the music")
        #expect(repaired["action"] == "next")
    }

    /// A MISSING OR GARBLED VALUE IS REPAIRED FROM THE WORDS — Bonnie's
    /// per-adapter rescue, now available to every package.
    @Test func aMissingOrGarbledValueIsRepaired() {
        #expect(SpokenEnumExtractor.repaired(
            [:], parameters: [Self.transport()],
            utterance: "can you pause the music")["action"] == "pause")
        #expect(SpokenEnumExtractor.repaired(
            ["action": "halt"], parameters: [Self.transport()],
            utterance: "pause the music")["action"] == "pause")
    }

    /// NOTHING SAID, NOTHING ADDED. A required value the words do not name
    /// keeps failing in the binding, where the refusal can say what it wanted.
    @Test func anUnspokenValueIsNotInvented() {
        let repaired = SpokenEnumExtractor.repaired(
            [:], parameters: [Self.transport()], utterance: "do something to it")
        #expect(repaired["action"] == nil)
    }
}
