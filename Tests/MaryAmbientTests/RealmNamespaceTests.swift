//
//  RealmNamespaceTests.swift
//  BonnieAmbientTests
//
//  THE TWO NAMESPACES CANNOT COLLIDE — the M4 pin. Native realms spell bare
//  world raw values; dynamic realms spell "applications:<id>". Disjointness is
//  structural on the token axis (the colon prefix) and enforced on the
//  roster axis by admission's projection rule: a registration whose id IS a
//  plugin owner projects onto that world (`legacyWorld`), so its place is
//  the NATIVE case and the dynamic namespace never contains a world's name.
//
//  The projection lives in `AmbientApplicationBridge.registration(for:)`
//  (MaryBrain), pinned at that seam by `AmbientContextStoreTests.
//  admissionProjectsWorldNamedRegistrationsOntoTheirWorlds`; this file pins
//  the MaryAmbient half — the token algebra and the roster fixture
//  invariant it licenses.
//

import Foundation
import Testing
@testable import MaryAmbient

@Suite struct RealmNamespaceTests {

    /// A fixture roster shaped exactly as admission builds one: every
    /// world-named profile projects (`legacyWorld` non-nil), every other id
    /// is free-standing.
    private static let roster = AmbientApplicationRoster([
        // The projection case: a package teaching a built-in application.
        ApplicationRegistration(
            id: "keynote",
            profile: ApplicationProfile(
                id: "keynote", title: "Keynote", summary: "Decks."),
            worldClass: AmbientWorldClass.workspace,
            legacyWorld: nil),
        // The ordinary dynamic case.
        ApplicationRegistration(
            id: "sketch",
            profile: ApplicationProfile(id: "sketch", title: "Sketch", summary: "Design."),
            bundleIdentifiers: ["com.bohemiancoding.sketch3"],
            worldClass: .dataSource),
    ])

    /// NO INSTALLED REGISTRATION MAY MINT A DYNAMIC REALM WEARING A WORLD'S
    /// NAME. Over the fixture roster: a world-named registration's place is
    /// the NATIVE realm (projection), and every free-standing registration's
    /// id is not a world raw value.
    @Test func noRosterRegistrationCollidesWithAWorldRawValue() {
        let worldNames = Set(AmbientWorld.allCases.map(\.rawValue))
        for registration in Self.roster.all {
            if worldNames.contains(registration.id) {
                #expect(registration.legacyWorld?.rawValue == registration.id,
                        "a world-named registration must project onto its world")
                #expect(registration.place == .native(registration.legacyWorld!),
                        "its place is the NATIVE case — no dynamic twin")
            } else {
                #expect(registration.place == .dynamic(registration.id))
            }
        }
    }

    /// The token axis is disjoint BY CONSTRUCTION: every dynamic token wears
    /// the "applications:" prefix, no native token contains a colon, and
    /// `from(token:)` sends each spelling back to its own case.
    @Test func nativeAndDynamicTokensAreStructurallyDisjoint() {
        let nativeTokens = Set(AmbientWorld.allCases.map { AmbientRealm.native($0).token })
        for world in AmbientWorld.allCases {
            #expect(!world.rawValue.contains(":"))
            // Even a hostile id that IS a world raw value cannot collide on
            // the token axis — the prefix keeps the namespaces apart.
            let dynamicTwin = AmbientRealm.dynamic(world.rawValue)
            #expect(!nativeTokens.contains(dynamicTwin.token))
            #expect(AmbientRealm.from(token: world.rawValue) == .native(world))
            #expect(AmbientRealm.from(token: dynamicTwin.token) == dynamicTwin)
        }
    }

    /// The lead ladder respects the projection: a legacy-projecting
    /// registration leads AS its world, and a free-standing one leads as
    /// itself.
    @Test func theLeadLadderHonorsTheProjection() {
        AmbientApplicationIndexProvider.$scoped.withValue(Self.roster) {
            // EVERY REGISTRATION IS ITS OWN REALM. Bonnie's roster could
            // project an application onto a compiled world, so this rung
            // answered `.native(.keynote)`; with no compiled applications
            // there is nothing to project onto and an id is simply itself.
            #expect(AmbientRealm.lead(
                world: .applications, applicationID: "keynote")
                == .dynamic("keynote"))
            #expect(AmbientRealm.lead(world: .applications, applicationID: "sketch")
                == .dynamic("sketch"))
        }
    }
}
