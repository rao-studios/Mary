//
//  ContainerPlaceKeyingTests.swift
//  BonnieAmbientTests
//
//  THE CONTAINER LEDGER KEYS BY REALM — the M4 behavior change, pinned.
//
//  Before this, `ContainerRegistry` keyed everything by `AmbientWorld`, so a
//  registered application had NO container identity of its own: its containers
//  could only key under the shared `.applications` host lane, where two
//  applications' documents would collide. Keying by `AmbientPlace.token` gives
//  each registration its own `applications:<id>|…` namespace while every native
//  key stays byte-identical (`token == rawValue` for a native place).
//
//  If the byte-identity golden fails, the migration changed strings the
//  conversation, the debugger pane, and the evidence ledger already hold —
//  fix the code, never this file.
//

import Foundation
import Testing

@testable import MaryAmbient

@Suite struct ContainerPlaceKeyingTests {

    // MARK: - Dynamic identity

    /// A registered application can mint a handle of its own, and the handle
    /// resolves back to the application's place — not to a bare host lane.
    @Test func aRegisteredApplicationMintsItsOwnHandles() {
        let registry = ContainerRegistry()
        let handle = registry.handle(
            place: .application("sketch"), prefix: "A", key: "canvas-1")
        #expect(!handle.isEmpty)

        let found = registry.resolvePlace(handle)
        #expect(found?.place == .application("sketch"))
        #expect(found?.key == "canvas-1")

        // The world projection still answers — with the host lane, which is
        // all a "is this one of TextEdit's?" caller ever asks.
        #expect(registry.resolve(handle)?.world == .applications)

        // Idempotent by (place, key), exactly as native minting is.
        #expect(registry.handle(
            place: .application("sketch"), prefix: "A", key: "canvas-1") == handle)
    }

    /// A registered application can enroll a listing under its own place, and
    /// the listing is the application's — not the host lane's.
    @Test func aRegisteredApplicationEnrollsAListing() {
        let registry = ContainerRegistry()
        registry.noteListing(
            place: .application("sketch"), keys: ["canvas-1", "canvas-2"])

        let remembered = registry.lastListing(for: AmbientPlace.application("sketch"))
        #expect(remembered?.keys == ["canvas-1", "canvas-2"])
        #expect(remembered?.place == .application("sketch"))
        // The world half is the host lane it rides.
        #expect(remembered?.world == .applications)

        // Live-check passes while the enumeration agrees, fails when it moves.
        #expect(registry.listing(
            for: AmbientPlace.application("sketch"),
            against: ["canvas-1", "canvas-2"]) != nil)
        #expect(registry.listing(
            for: AmbientPlace.application("sketch"),
            against: ["canvas-2", "canvas-1"]) == nil)

        // The application's listing is NOT the host lane's listing: the bare
        // `.applications` world holds no listing because the application holds it.
        #expect(registry.lastListing(for: AmbientWorld.applications) == nil)

        // And a listing stamps `.shown` under the application's own identity.
        #expect(registry.evidence(
            place: .application("sketch"), key: "canvas-1")?.kind == .shown)
        #expect(registry.evidence(world: .applications, key: "canvas-1") == nil)
    }

    // MARK: - Key spelling

    /// EVIDENCE KEYS CARRY THE FULL REALM TOKEN, application and all.
    ///
    /// Bonnie pinned these as byte-identical to a pre-existing world-keyed
    /// ledger, because it had persisted rows to keep readable. Mary has no
    /// history to preserve, so the pin is a different one: the key must be
    /// COLLISION-FREE, which means it carries the lane prefix a dynamic place
    /// uses. Two applications naming the same document key must not share an
    /// evidence row.
    @Test func evidenceKeysCarryTheWholeRealm() {
        #expect(ContainerRegistry.evidenceKey(
            place: .application("textedit"), key: "/tmp/todo.txt")
            == "applications:textedit|/tmp/todo.txt")
        #expect(ContainerRegistry.evidenceKey(
            place: .application("notes"), key: "/tmp/todo.txt")
            != ContainerRegistry.evidenceKey(
                place: .application("textedit"), key: "/tmp/todo.txt"),
            "two applications sharing a document key must not share evidence")

        // A representative handle: the first TextEdit mint was "W1" before the
        // re-key and is "W1" after, minted off the identical scoped identifier.
        let registry = ContainerRegistry()
        let handle = registry.handle(place: .application("textedit"), prefix: "W", key: "/tmp/todo.txt")
        #expect(handle == "W1")
        // Place-form minting for the same native container reuses it — the
        // scoped identifiers are the same bytes, so the map cannot tell the
        // two spellings apart.
        #expect(registry.handle(
            place: .application("textedit"), prefix: "W", key: "/tmp/todo.txt") == "W1")

        // The dynamic namespace is the prefixed one; native never wears it.
        #expect(ContainerRegistry.evidenceKey(
            place: .application("sketch"), key: "canvas-1")
            == "applications:sketch|canvas-1")
    }

    // MARK: - Disjointness

    /// Two registered applications sharing the host lane (and even a handle
    /// prefix) keep fully disjoint containers: handles, evidence, listings.
    @Test func twoRegisteredApplicationsContainersStayDisjoint() {
        let registry = ContainerRegistry()

        // Same prefix, same key — different applications, different handles.
        let sketch = registry.handle(place: .application("sketch"), prefix: "A", key: "canvas-1")
        let figma = registry.handle(place: .application("figma"), prefix: "A", key: "canvas-1")
        #expect(sketch != figma)
        #expect(registry.resolvePlace(sketch)?.place == .application("sketch"))
        #expect(registry.resolvePlace(figma)?.place == .application("figma"))

        // Evidence stamped for one never answers for the other.
        registry.noteEvidence(place: .application("sketch"), key: "canvas-1", .actedOn)
        #expect(registry.evidence(
            place: .application("sketch"), key: "canvas-1")?.kind == .actedOn)
        #expect(registry.evidence(place: .application("figma"), key: "canvas-1") == nil)

        // Listings are per-application, not per host lane.
        registry.noteListing(place: .application("sketch"), keys: ["canvas-1"])
        registry.noteListing(place: .application("figma"), keys: ["board-1"])
        #expect(registry.lastListing(
            for: AmbientPlace.application("sketch"))?.keys == ["canvas-1"])
        #expect(registry.lastListing(
            for: AmbientPlace.application("figma"))?.keys == ["board-1"])

        // And salience under one application sees only its own evidence:
        // sketch's `.actedOn` on "canvas-1" must not rank figma's "canvas-1".
        #expect(registry.salienceRanks(
            place: .application("figma"), keys: ["canvas-1"]).isEmpty)
    }
}
