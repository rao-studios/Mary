//
//  SurfaceRosterTests.swift
//  MaryAmbientTests
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct SurfaceRosterTests {

    private var quill: ApplicationRegistration {
        ApplicationRegistration(
            id: "quill",
            profile: ApplicationProfile(
                id: "quill", title: "Quill", summary: "A fixture.",
                abilities: ["writing"]),
            bundleIdentifiers: ["com.example.quill"],
            worldClass: .workspace)
    }

    private var forge: ApplicationRegistration {
        ApplicationRegistration(
            id: "forge",
            profile: ApplicationProfile(
                id: "forge", title: "Forge", summary: "A fixture.",
                abilities: ["coding"]),
            bundleIdentifiers: ["com.example.forge"],
            worldClass: .workspace)
    }

    @Test func reconcileReplacesTheWholeRoster() {
        let roster = SurfaceRoster<ApplicationRegistration>()
        roster.reconcile([quill])
        #expect(roster.all().map(\.applicationID) == ["quill"])
        roster.reconcile([forge])
        #expect(roster.all().map(\.applicationID) == ["forge"])
        #expect(roster.registration(applicationID: "quill") == nil)
    }

    @Test func bundleLookupUsesOwns() {
        let roster = SurfaceRoster<ApplicationRegistration>()
        roster.reconcile([quill])
        #expect(roster.registration(bundleID: "com.example.quill")?.applicationID == "quill")
        #expect(roster.registration(bundleID: "com.example.forge") == nil)
    }
}

@Suite struct SurfaceClaimOwnershipTests {

    @Test func exactThenFamilyRefusesAHyphenatedDifferentProduct() {
        #expect(
            SurfaceClaimOwnership.exactThenFamily(
                bundleID: "com.apple.dt.Xcode",
                identifiers: ["com.apple.dt.Xcode"],
                prefix: "com.apple.dt.Xcode"))
        #expect(
            !SurfaceClaimOwnership.exactThenFamily(
                bundleID: "com.apple.dt.Xcode-beta",
                identifiers: ["com.apple.dt.Xcode"],
                prefix: "com.apple.dt.Xcode"),
            "isInFamily treats a hyphen as a different word — corpus must not silently adopt it")
    }

    @Test func declaredStemStillClaimsAVersionedOrBetaIdentity() {
        #expect(
            SurfaceClaimOwnership.declaredStem(
                bundleID: "com.apple.dt.Xcode-beta",
                identifiers: ["com.apple.dt.Xcode"]))
        #expect(
            SurfaceClaimOwnership.declaredStem(
                bundleID: "com.literatureandlatte.scrivener3",
                identifiers: ["com.literatureandlatte.scrivener"]))
    }
}
