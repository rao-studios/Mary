//
//  AmbientRealmABITests.swift
//  BonnieAmbientTests
//
//  THE TOKEN ABI, PINNED BEFORE THE REALM MIGRATION MOVES ANYTHING. These
//  goldens are invariants 2/4/9 of the AmbientRealm plan made executable:
//  native tokens ARE the raw values (package ABI + key ids + report bytes),
//  registered applications spell "applications:<id>", and the host-lane shape
//  is fixed — a registered application NEVER pairs with any world but
//  `.applications` (the audit that licenses `AmbientRealm.dynamic(String)`
//  carrying no host world of its own).
//
//  If one of these fails during the migration, the migration changed an ABI
//  it promised not to touch — fix the code, never this file.
//

import Foundation
import Testing
@testable import MaryAmbient

struct AmbientRealmABITests {

    private static let roster = AmbientApplicationRoster([
        ApplicationRegistration(
            id: "sketch",
            profile: ApplicationProfile(id: "sketch", title: "Sketch", summary: "Design."),
            bundleIdentifiers: ["com.bohemiancoding.sketch3"],
            worldClass: .dataSource)
    ])

    /// Every native place token is byte-identical to the world's raw value —
    /// key ids, pane row ids, report tokens, and package application ids all
    /// ride this equality.
    @Test func everyNativeTokenIsItsRawValue() {
        for world in AmbientWorld.allCases {
            #expect(AmbientRealm.world(world).token == world.rawValue)
        }
    }

    /// The registered spelling, and the unregistered fallback, both on the
    /// `.applications` host lane with a colon — the report/pane split on the
    /// FIRST "/" must survive.
    @Test func registeredTokensRideTheHostLane() {
        AmbientApplicationIndexProvider.$scoped.withValue(Self.roster) {
            #expect(AmbientRealm(world: .applications, application: "sketch").token
                == "applications:sketch")
            #expect(AmbientRealm(world: .applications, application: "ghost").token
                == "applications:ghost")
        }
    }

    /// Key ids compose place token + slot token behind one "/" — the exact
    /// strings pinned across the debugger, reports, and tests.
    @Test func keyIDsAreByteStable() {
        // EVERY APPLICATION RIDES THE LANE. Bonnie's compiled worlds keyed
        // bare ("pages/file"); an application is a guest on the applications
        // lane, and its key says so.
        let application = AmbientKey(place: .dynamic("pages"), slot: .file)
        #expect(application.id == "applications:pages/\(AmbientSlot.file.token)")
        // A LANE of Mary's own still keys bare — it answers for itself.
        let lane = AmbientKey(place: .native(.typer), slot: .file)
        #expect(lane.id == "typer/\(AmbientSlot.file.token)")
        let registered = AmbientKey(
            place: AmbientRealm(world: .applications, application: "sketch"),
            slot: .viewport)
        #expect(registered.id == "applications:sketch/\(AmbientSlot.viewport.token)")
    }

    /// THE HOST-LANE SHAPE: a registration with no built-in counterpart
    /// addresses itself as (.applications, id); one WITH a legacy world IS that
    /// world, never a discriminated lane inside it. This is the audit that
    /// lets the realm collapse (world, application?) into two enum cases.
    @Test func registrationPlacesFixTheHostLane() {
        let dynamic = ApplicationRegistration(
            id: "sketch",
            profile: ApplicationProfile(id: "sketch", title: "Sketch", summary: "Design."),
            bundleIdentifiers: ["com.bohemiancoding.sketch3"],
            worldClass: .dataSource)
        #expect(dynamic.place == AmbientRealm(world: .applications, application: "sketch"))
        let native = ApplicationRegistration(
            id: "pages",
            profile: ApplicationProfile(id: "pages", title: "Pages", summary: "Writing."),
            bundleIdentifiers: ["com.apple.iWork.Pages"],
            worldClass: .workspace,
            legacyWorld: nil)
        #expect(native.place == AmbientRealm.dynamic("pages"))
        #expect(native.place.application == "pages",
                "every application is a dynamic realm carrying its own id")
    }

    /// The bare persisted spelling: the memory graph stores "pages" and
    /// "sketch" as peers with NO prefix — the realm's memory token must keep
    /// emitting exactly these (a prefixed token would orphan every
    /// previously-deposited row, and there is no version field to migrate on).
    @Test func persistedSpellingsStayBare() {
        AmbientApplicationIndexProvider.$scoped.withValue(Self.roster) {
            let place = AmbientRealm(world: .applications, application: "sketch")
            #expect(place.application == "sketch",
                    "the bare id is the persisted spelling — never place.token")
        }
    }

    /// EVERY LANE ROUND-TRIPS THROUGH ITS TOKEN. The memory graph and the
    /// behavioural dataset both key on these strings, so a lane whose token
    /// does not parse back orphans everything ever written about it.
    @Test func everyLaneRoundTripsThroughItsToken() {
        for world in AmbientWorld.allCases {
            let realm = AmbientRealm.native(world)
            #expect(AmbientRealm.from(token: realm.token) == realm, "\(world)")
            #expect(AmbientWorld.from(pluginOwner: world.pluginOwner) == world, "\(world)")
        }
    }

    /// AND SO DOES EVERY APPLICATION. A dynamic realm's token carries the
    /// host lane as a prefix so it can never collide with a lane's own token;
    /// its MEMORY token stays bare, because the graph stores application ids
    /// as peers with no prefix and there is no version field to migrate on.
    @Test func applicationsRoundTripAndPersistBare() {
        let place = AmbientRealm.dynamic("textedit")
        #expect(AmbientRealm.from(token: place.token) == place)
        #expect(place.memoryToken == "textedit")
        #expect(place.token != place.memoryToken,
                "the collision-free token and the persisted one are different jobs")
    }

    /// Render order: natives keep their exact positions; registrations sort
    /// after every native, in roster order — the golden prompt diff depends
    /// on adding a registration never reordering the worlds.
    @Test func orderKeepsNativesFirst() {
        AmbientApplicationIndexProvider.$scoped.withValue(Self.roster) {
            let registered = AmbientRealm(world: .applications, application: "sketch")
            for world in AmbientWorld.allCases {
                #expect(AmbientRealm.world(world).order == world.order)
                #expect(registered.order > world.order)
            }
        }
    }

    /// THE MEMORY-GRAPH SPELLING, as its own golden: native realms deposit
    /// their bare rawValue and dynamic realms their bare id — peers, no
    /// prefix — because the graph has no version field to migrate on and a
    /// prefixed token would orphan every previously-deposited row.
    @Test func memoryTokensStayBare() {
        for world in AmbientWorld.allCases {
            #expect(AmbientRealm.native(world).memoryToken == world.rawValue)
        }
        #expect(AmbientRealm.dynamic("sketch").memoryToken == "sketch")
        #expect(AmbientRealm.dynamic("ghost").memoryToken == "ghost")
    }

    /// `from(token:)` is the exact inverse of `token`: every realm round-trips,
    /// dynamics split on the FIRST colon under the "other_apps" prefix, and a
    /// spelling that is neither a world rawValue nor a host-lane token is not
    /// a realm.
    @Test func tokensRoundTrip() {
        for world in AmbientWorld.allCases {
            #expect(AmbientRealm.from(token: AmbientRealm.native(world).token)
                == .native(world))
        }
        #expect(AmbientRealm.from(token: AmbientRealm.dynamic("sketch").token)
            == .dynamic("sketch"))
        #expect(AmbientRealm.from(token: "applications:read:doc") == .dynamic("read:doc"),
                "the first colon is the split; the id keeps the rest")
        #expect(AmbientRealm.from(token: "not-a-world") == nil)
        #expect(AmbientRealm.from(token: "pages:sketch") == nil,
                "only the host lane spells dynamics")
        #expect(AmbientRealm.from(token: "applications:") == nil,
                "an empty id is not an identity")
        #expect(AmbientRealm.from(token: "applications") == .native(.applications),
                "the bare host lane is the native world, not a dynamic")
    }
}
