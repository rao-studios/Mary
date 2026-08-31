//
//  MediaSurfaceLaunchTests.swift
//  MaryPluginTests
//
//  WHAT: Launch picks a named player or the only declared one; never guesses.
//  OUT:  MediaSurfaceLaunch.launchTarget
//

import Testing
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct MediaSurfaceLaunchTests {

    @Test func aNamedPlayerIsTheLaunchTargetEvenAmongSeveral() {
        let music = player(id: "apple-music", name: "Music")
        let spotify = player(id: "spotify", name: "Spotify")
        let hit = MediaSurfaceLaunch.launchTarget(
            named: "apple-music", declared: [music, spotify])
        #expect(hit?.applicationID == "apple-music")
        #expect(
            MediaSurfaceLaunch.launchTarget(
                named: "Music", declared: [music, spotify])?.applicationID
                == "apple-music")
    }

    @Test func theOnlyDeclaredPlayerLaunchesWhenUnnamed() {
        let music = player(id: "apple-music", name: "Music")
        let hit = MediaSurfaceLaunch.launchTarget(named: nil, declared: [music])
        #expect(hit?.applicationID == "apple-music")
    }

    @Test func severalDeclaredPlayersAreNeverGuessed() {
        let music = player(id: "apple-music", name: "Music")
        let spotify = player(id: "spotify", name: "Spotify")
        #expect(
            MediaSurfaceLaunch.launchTarget(
                named: nil, declared: [music, spotify]) == nil)
        #expect(
            MediaSurfaceLaunch.launchTarget(
                named: "", declared: [music, spotify]) == nil)
    }

    private func player(id: String, name: String) -> MediaSurfaceRegistration {
        MediaSurfaceRegistration(
            applicationID: id,
            bundleIdentifiers: ["com.example.\(id)"],
            displayName: name,
            schema: PluginMediaSurfaceSchema(
                transportLabel: "Playback",
                playingLabel: "Play",
                pausedLabel: "Paused"))
    }
}
