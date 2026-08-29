//
//  SurfacePollTargetTests.swift
//  MaryAmbientTests
//
//  WHICH PROCESS TO WALK, independent of what the walk reads. Claims are
//  `ApplicationRegistration` so this suite never names a code surface.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct SurfacePollTargetTests {

    private var xcode: ApplicationRegistration {
        ApplicationRegistration(
            id: "xcode",
            profile: ApplicationProfile(
                id: "xcode", title: "Xcode", summary: "One code editor.",
                abilities: ["coding"]),
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            worldClass: .workspace)
    }

    private var vscode: ApplicationRegistration {
        ApplicationRegistration(
            id: "vscode",
            profile: ApplicationProfile(
                id: "vscode", title: "VS Code", summary: "Another editor.",
                abilities: ["coding"]),
            bundleIdentifiers: ["com.microsoft.VSCode"],
            worldClass: .workspace)
    }

    private var xcodeProcess: SurfacePollTarget.Process {
        .init(bundleID: "com.apple.dt.Xcode", pid: 42)
    }

    @Test func maryFrontmostSamplesARunningClaim() {
        let hit = SurfacePollTarget.resolve(
            frontmostBundleID: "nyc.rao.mary",
            maryBundleID: "nyc.rao.mary",
            claims: [xcode],
            running: [xcodeProcess],
            preferredApplicationIDs: [])
        #expect(hit?.applicationID == "xcode")
        #expect(hit?.pid == 42)
        #expect(hit?.isFrontmost == false)
    }

    @Test func aForeignFrontmostDoesNotPullABackgroundClaim() {
        let hit = SurfacePollTarget.resolve(
            frontmostBundleID: "com.apple.Safari",
            maryBundleID: "nyc.rao.mary",
            claims: [xcode],
            running: [xcodeProcess],
            preferredApplicationIDs: ["xcode"])
        #expect(hit == nil)
    }

    @Test func aFrontmostClaimWinsOverAStandingPreference() {
        let hit = SurfacePollTarget.resolve(
            frontmostBundleID: "com.apple.dt.Xcode",
            maryBundleID: "nyc.rao.mary",
            claims: [xcode, vscode],
            running: [
                xcodeProcess,
                .init(bundleID: "com.microsoft.VSCode", pid: 99),
            ],
            preferredApplicationIDs: ["vscode"])
        #expect(hit?.applicationID == "xcode")
        #expect(hit?.isFrontmost == true)
    }

    @Test func theStandingIdBeatsAnotherRunningClaim() {
        let hit = SurfacePollTarget.resolve(
            frontmostBundleID: "nyc.rao.mary",
            maryBundleID: "nyc.rao.mary",
            claims: [xcode, vscode],
            running: [
                xcodeProcess,
                .init(bundleID: "com.microsoft.VSCode", pid: 99),
            ],
            preferredApplicationIDs: ["vscode"])
        #expect(hit?.applicationID == "vscode")
        #expect(hit?.pid == 99)
        #expect(hit?.isFrontmost == false)
    }

    @Test func systemChromeIsAsTransparentAsMary() {
        #expect(WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: "com.apple.dock", maryBundleID: "nyc.rao.mary"))
        #expect(WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: nil, maryBundleID: "nyc.rao.mary"))
        #expect(!WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: "com.apple.Safari", maryBundleID: "nyc.rao.mary"))
        let hit = SurfacePollTarget.resolve(
            frontmostBundleID: "com.apple.dock",
            maryBundleID: "nyc.rao.mary",
            claims: [xcode],
            running: [xcodeProcess],
            preferredApplicationIDs: [])
        #expect(hit?.applicationID == "xcode")
        #expect(hit?.isFrontmost == false)
    }

    @Test func ambientDoesNotPickARandomRunningApp() {
        let hit = SurfacePollTarget.resolve(
            frontmostBundleID: "nyc.rao.mary",
            maryBundleID: "nyc.rao.mary",
            claims: [xcode],
            running: [xcodeProcess],
            preferredApplicationIDs: [],
            unpreferredFallback: false)
        #expect(hit == nil)
    }

    @Test func pidLookupUsesTheInjectedRunningList() {
        #expect(
            SurfacePollTarget.pid(of: xcode, running: [xcodeProcess]) == 42)
        #expect(SurfacePollTarget.pid(of: xcode, running: []) == nil)
    }
}
