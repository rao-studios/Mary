//
//  MediaTransportReceiptTests.swift
//  MaryPluginTests
//
//  WHAT: What a transport key may claim afterwards.
//  OUT:  MediaSurfaceAdapter.movement / transportSummary
//  PIN:  "Paused." WAS A CLAIM NOBODY CHECKED. The old summary said the verb in
//        the past tense whether a player existed, whether it was playing, and
//        whether anything reacted — so a pause against silence and a pause that
//        worked read identically, and `landed` was never set at all.
//

import Foundation
import Testing
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct MediaTransportReceiptTests {

    private static func reading(
        playing: Bool?, title: String? = "A Song"
    ) -> MediaSurfaceAX.Reading {
        MediaSurfaceAX.Reading(title: title, isPlaying: playing)
    }

    // MARK: - Did it move?

    /// Play and pause flip a state that can be read directly.
    @Test func aTransportFlipIsMovement() {
        #expect(MediaSurfaceAdapter.movement(
            from: Self.reading(playing: true),
            to: Self.reading(playing: false),
            for: .pause) == true)
        #expect(MediaSurfaceAdapter.movement(
            from: Self.reading(playing: true),
            to: Self.reading(playing: true),
            for: .pause) == false)
    }

    /// Next and previous leave the state alone and change the TITLE — so that
    /// is what is read for them.
    @Test func aTrackChangeIsMovementForSkipping() {
        #expect(MediaSurfaceAdapter.movement(
            from: Self.reading(playing: true, title: "One"),
            to: Self.reading(playing: true, title: "Two"),
            for: .next) == true)
        #expect(MediaSurfaceAdapter.movement(
            from: Self.reading(playing: true, title: "One"),
            to: Self.reading(playing: true, title: "One"),
            for: .next) == false)
    }

    /// UNKNOWABLE IS NOT FALSE. Volume and mute move a system level this
    /// adapter cannot see through a player's transport, and nothing readable
    /// either side is a third answer — reporting either as failure would be a
    /// lie about a key that very likely worked.
    @Test func whatCannotBeSeenIsNotReportedAsFailure() {
        #expect(MediaSurfaceAdapter.movement(
            from: Self.reading(playing: true),
            to: Self.reading(playing: true),
            for: .louder) == nil)
        #expect(MediaSurfaceAdapter.movement(
            from: nil, to: Self.reading(playing: true), for: .pause) == nil)
        #expect(MediaSurfaceAdapter.movement(
            from: Self.reading(playing: nil),
            to: Self.reading(playing: nil),
            for: .pause) == nil)
    }

    // MARK: - What it says

    /// NO PLAYER ANSWERED. The key still went to the system — something
    /// unregistered may well have taken it — so this says what was sent and
    /// admits it cannot confirm.
    @Test func withNoPlayerItSaysItCannotConfirm() {
        let summary = MediaSurfaceAdapter.transportSummary(
            action: .pause, before: nil, settled: nil, landed: nil)
        #expect(summary.contains("can't see a player"))
        #expect(summary.contains("pause"))
    }

    /// PRESSED, AND NOTHING MOVED. A real miss, said plainly rather than
    /// reported as the verb.
    @Test func aPressThatChangedNothingSaysSo() {
        let registration = MediaSurfaceRegistration(
            applicationID: "test-player",
            bundleIdentifiers: ["com.example.player"],
            displayName: "Test Player",
            schema: PluginMediaSurfaceSchema(
                transportLabel: "Playback",
                playingLabel: "Play",
                pausedLabel: "Paused"))
        let summary = MediaSurfaceAdapter.transportSummary(
            action: .pause,
            before: Self.reading(playing: true),
            settled: (Self.reading(playing: true), registration),
            landed: false)
        #expect(summary.contains("didn't move"))
        #expect(summary.contains("Test Player"))
    }
}
