//
//  BehavioralPairParityTests.swift
//  MaryFoundationTests
//
//  WHAT: The input half of a training pair, pinned to bytes.
//  OUT:  BehavioralTrainingInput
//  PIN:  THE OTHER HALF OF THIS TEST LIVES IN FLEET. The same fixture episode
//        and the same expected bytes are checked into
//        Fleet/Tests/FleetTests/Fixtures, where `BehavioralPairProjector`
//        must produce them too. Two hand-kept copies of one projection is how
//        the lead token came to be spelled two different ways; this pair of
//        tests is what makes a drift fail on the side that caused it.
//

import Foundation
import Testing
@testable import MaryFoundation

@Suite struct BehavioralPairParityTests {

    private static func fixture(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        return try Data(contentsOf: url)
    }

    /// Canonical form: sorted keys, no whitespace — the bytes Fleet hashes.
    private static func canonical(_ data: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: data)
        let bytes = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test func theInputProjectionMatchesTheSharedGolden() throws {
        let episode = try BehavioralCodec.episode(
            from: try Self.fixture("behavior-parity-episode.json"))
        let pair = BehavioralTrainingPair(episode: episode)

        let produced = try Self.canonical(try pair.encodedInput())
        let expected = try Self.canonical(try Self.fixture("behavior-parity-input.json"))

        #expect(produced == expected)
    }

    /// The lead is spelled the way the capture builder spells it — with its
    /// lane prefix. The idle path used the bare `memoryToken`, so every idle
    /// inference arrived with a token the adapter had never been trained on.
    @Test func theLeadCarriesItsLanePrefix() throws {
        let episode = try BehavioralCodec.episode(
            from: try Self.fixture("behavior-parity-episode.json"))
        let input = BehavioralTrainingInput(episode: episode)

        #expect(input.ambientLead == "applications:textedit")
        #expect(input.ambientMode == "focusedWorld")
        #expect(input.factCount == 2)
    }

    /// The summary is the rendered blocks and mentions in reading order —
    /// what the model was actually shown, not a scrape of the fact store.
    @Test func theSummaryIsTheRenderedTextInOrder() throws {
        let episode = try BehavioralCodec.episode(
            from: try Self.fixture("behavior-parity-episode.json"))
        let input = BehavioralTrainingInput(episode: episode)

        #expect(input.ambientSummary
            == "applications:textedit Essay — 1,840 characters Cursor at line 12")
    }

    @Test func everyKeyIsPresentEvenWhenNothingIsInFront() throws {
        let bare = BehavioralTrainingInput(input: BehavioralInput(query: "hello"))
        let produced = try Self.canonical(try BehavioralCodec.encoder().encode(bare))

        for key in [
            "ambient_lead", "ambient_mode", "ambient_summary",
            "fact_count", "prior_episode_id", "query",
        ] {
            #expect(produced.contains("\"\(key)\""))
        }
    }
}
