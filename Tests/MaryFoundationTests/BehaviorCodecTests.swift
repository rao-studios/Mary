//
//  BehaviorCodecTests.swift
//  MaryFoundationTests
//
//  WHAT: Behavioral episode line codec — byte-stable, absent ≠ empty.
//  OUT:  BehavioralCodec
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryFoundation

@Suite struct BehaviorCodecTests {

    // MARK: - Byte stability

    @Test func anEpisodeEncodesIdenticallyEveryTime() throws {
        let episode = BehaviorFixtures.typedIntoTextEdit
        let first = try BehavioralCodec.line(episode)
        let second = try BehavioralCodec.line(episode)
        #expect(first == second)
    }

    @Test func anEpisodeSurvivesARoundTripByteForByte() throws {
        let encoded = try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit)
        let decoded = try BehavioralCodec.episode(from: encoded)
        #expect(decoded == BehaviorFixtures.typedIntoTextEdit)
        #expect(try BehavioralCodec.line(decoded) == encoded)
    }

    /// THE STORE APPENDS ONE EPISODE PER LINE. A pretty-printed encoder would
    /// corrupt the file it writes into, so the absence of newlines is a
    /// correctness property rather than a formatting preference.
    @Test func anEncodedEpisodeIsOneLine() throws {
        let encoded = try BehavioralCodec.line(BehaviorFixtures.typedIntoTextEdit)
        #expect(!encoded.contains(0x0A))
    }

    // MARK: - Tolerance

    /// An older reader must not choke on a newer writer's additions. This is
    /// the opposite posture from a `.mary` package, where an unknown key is a
    /// byte missing from a verified digest — see the codec headers.
    @Test func anUnknownKeyIsIgnoredRatherThanRefused() throws {
        var object = try episodeObject(BehaviorFixtures.typedIntoTextEdit)
        object["somethingFromTheFuture"] = ["nested": true]
        let decoded = try BehavioralCodec.decoder().decode(
            BehavioralEpisode.self,
            from: try JSONSerialization.data(withJSONObject: object))
        #expect(decoded.id == BehaviorFixtures.typedIntoTextEdit.id)
    }

    // MARK: - Absent is not empty

    @Test func aNilCaptureAndAnEmptyCaptureAreDifferentRows() throws {
        var withoutCapture = BehaviorFixtures.typedIntoTextEdit
        withoutCapture.input.ambient = nil
        var withEmptyCapture = BehaviorFixtures.typedIntoTextEdit
        withEmptyCapture.input.ambient = .empty(mode: "relevance")

        let a = try BehavioralCodec.line(withoutCapture)
        let b = try BehavioralCodec.line(withEmptyCapture)
        #expect(a != b)
        #expect(try BehavioralCodec.episode(from: a).input.ambient == nil)
        #expect(try BehavioralCodec.episode(from: b).input.ambient?.isEmpty == true)
    }

    // MARK: - Helpers

    private func episodeObject(_ episode: BehavioralEpisode) throws -> [String: Any] {
        let data = try BehavioralCodec.line(episode)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
