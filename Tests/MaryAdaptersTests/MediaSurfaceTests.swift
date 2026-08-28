//
//  MediaSurfaceTests.swift
//  MaryAdaptersTests
//
//  THE LABEL LADDER, which is where a media declaration can be quietly wrong.
//
//  The live probe (`mary-media-probe`) proves a declaration describes a real
//  player. What it cannot prove is the behaviour of labels it did not happen
//  to meet: a player whose off-word contains its on-word, a control renamed
//  by a system update, a mode this application does not expose at all. Those
//  are decided here, against fixtures, because each one is a rule rather than
//  a reading.
//

import Foundation
import Testing
import MaryFoundation
@testable import MaryAdapters

@Suite struct MediaSurfaceTests {

    /// Apple Music's own words, measured with the AX probe — the fixture is
    /// real rather than invented, so a rule that passes here passes there.
    private func registration(
        shuffle: PluginMediaToggleLabels? = .init(on: "shuffle", off: "do not shuffle"),
        repeatMode: PluginMediaToggleLabels? = .init(on: "repeat", off: "do not repeat")
    ) -> MediaSurfaceRegistration {
        MediaSurfaceRegistration(
            applicationID: "player",
            bundleIdentifiers: ["com.example.player"],
            displayName: "Player",
            schema: PluginMediaSurfaceSchema(
                transportLabel: "Mini Player",
                playingLabel: "Pause",
                pausedLabel: "Play",
                shuffle: shuffle,
                repeatMode: repeatMode,
                positionLabel: "Track Position"))
    }

    // MARK: - The state is in the label

    @Test func theButtonSaysWhatPressingItWouldDo() {
        let player = registration()
        // A player that IS playing shows a button offering to pause.
        #expect(player.isPlayingLabel("Pause"))
        #expect(player.isPausedLabel("Play"))
        #expect(!player.isPlayingLabel("Play"))
    }

    /// CASE AND WHITESPACE ARE NOISE. Apple Music publishes "do not shuffle"
    /// in lower case beside "Pause" in title case, in the same eight-button
    /// bar — an author reading the bar with a probe writes down what they see,
    /// and a matcher that demanded exact bytes would fail whichever one they
    /// guessed wrong.
    @Test func labelsMatchRegardlessOfCaseAndPadding() {
        let player = registration()
        #expect(player.isPlayingLabel("  pause "))
        #expect(player.shuffleState("SHUFFLE") == true)
    }

    /// THE ORDERING BUG THIS PINS: "do not shuffle" CONTAINS "shuffle". A
    /// ladder that tested the on-word first would read every off state as on
    /// and report a player permanently shuffling.
    @Test func theOffWordWinsWhenItContainsTheOnWord() {
        let player = registration()
        #expect(player.shuffleState("do not shuffle") == false)
        #expect(player.shuffleState("shuffle") == true)
        #expect(player.repeatState("do not repeat") == false)
    }

    /// Repeat matches by PREFIX because a player distinguishes modes it
    /// cannot express in two words — and both are repeat being on.
    @Test func repeatMatchesEveryModeThatBeginsWithTheDeclaredWord() {
        let player = registration()
        #expect(player.repeatState("repeat one") == true)
        #expect(player.repeatState("repeat all") == true)
    }

    /// AN UNRECOGNIZED LABEL IS NOT AN "OFF". A control renamed by a system
    /// update means the read failed, and saying so lets the summary omit the
    /// mode instead of asserting a state nobody observed.
    @Test func anUnknownLabelReadsAsUnknownRatherThanOff() {
        #expect(registration().shuffleState("Randomize") == nil)
    }

    /// A mode the application does not expose is nil everywhere, rather than
    /// a false that would print "shuffle is off" about a player with no
    /// shuffle control at all.
    @Test func anUndeclaredModeIsNeverGuessed() {
        let player = registration(shuffle: nil, repeatMode: nil)
        #expect(player.shuffleState("shuffle") == nil)
        #expect(player.repeatState("repeat one") == nil)
    }

    // MARK: - What Mary says back

    @Test func theSummaryNamesTheTrackAndThePlayer() {
        let spoken = MediaSurfaceAdapter.spoken(
            .init(title: "The Antidote", isPlaying: true, position: 0.5),
            registration: registration())
        #expect(spoken.contains("The Antidote"))
        #expect(spoken.contains("Player"))
        #expect(spoken.contains("50%"))
    }

    /// ABSENT FACTS ARE LEFT OUT. A player whose transport hides its shuffle
    /// control is not a player that is not shuffling, and a sentence that
    /// says "shuffle is off" about it is a confident lie.
    @Test func unreadModesAreNotMentioned() {
        let spoken = MediaSurfaceAdapter.spoken(
            .init(title: "Song", isPlaying: true, isShuffling: nil, isRepeating: nil),
            registration: registration())
        #expect(!spoken.lowercased().contains("shuffle"))
        #expect(!spoken.lowercased().contains("repeat"))
    }

    @Test func aPausedPlayerSaysSoRatherThanClaimingToPlay() {
        let spoken = MediaSurfaceAdapter.spoken(
            .init(title: "Song", isPlaying: false), registration: registration())
        #expect(spoken.hasPrefix("Paused"))
    }

    /// Nothing playing is a real answer, not an error.
    @Test func anIdlePlayerIsReportedAsIdle() {
        let spoken = MediaSurfaceAdapter.spoken(
            .init(title: nil, isPlaying: false), registration: registration())
        #expect(spoken.contains("Nothing is playing"))
    }

    // MARK: - Roster

    @Test func aPlaceResolvesToItsDeclaredPlayer() {
        let support = MediaSurfaceSupport()
        support.reconcile([registration()])
        #expect(support.registration(applicationID: "player") != nil)
        #expect(support.registration(bundleID: "com.example.player") != nil)
        #expect(support.registration(applicationID: "other") == nil)
    }

    /// Reconciliation REPLACES: a package that stops declaring a transport
    /// must stop having one.
    @Test func reconcilingDropsWhatIsNoLongerDeclared() {
        let support = MediaSurfaceSupport()
        support.reconcile([registration()])
        support.reconcile([])
        #expect(support.all().isEmpty)
    }

    // MARK: - The transport verbs

    /// PLAY AND PAUSE SEND THE SAME KEY, because the hardware has one and it
    /// is a toggle. Refusing "play" while paused would be absurd.
    @Test func playAndPauseShareTheToggleKey() {
        #expect(MediaSurfaceAdapter.MediaAction.play.key == .playPause)
        #expect(MediaSurfaceAdapter.MediaAction.pause.key == .playPause)
    }

    @Test func everyOfferedActionHasAKeyAndASentence() {
        for action in MediaSurfaceAdapter.MediaAction.allCases {
            #expect(!action.past.isEmpty)
            #expect(MediaTransport.Key.allCases.contains(action.key))
        }
    }
}
