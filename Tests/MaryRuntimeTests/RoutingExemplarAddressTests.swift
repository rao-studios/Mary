//
//  RoutingExemplarAddressTests.swift
//  MaryRuntimeTests
//
//  WHAT: The document id IS the label.
//  PIN:  A totem search returns documentID, text and score — and NOT the
//        `metadata` an index item accepts. So which Skill and which intent a
//        recalled lesson teaches has to be readable from its id alone. If this
//        round trip breaks, routing memory silently returns nothing: every hit
//        fails to parse and the loop looks merely empty.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryRuntime

@Suite struct RoutingExemplarAddressTests {

    @Test func aLessonSurvivesTheRoundTripThroughItsDocumentID() throws {
        let stored = RoutingExemplar(
            query: "put the running mix on",
            skillID: "multimedia.play-playlist",
            intent: AmbientIntent.operate.rawValue,
            ok: true,
            storedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let id = TotemContextStore.ExemplarAddress.documentID(for: stored)
        let recalled = try #require(TotemContextStore.ExemplarAddress.exemplar(
            documentID: id, text: stored.query))

        #expect(recalled.skillID == stored.skillID)
        #expect(recalled.intent == stored.intent)
        #expect(recalled.query == stored.query)
        #expect(recalled.storedAt == stored.storedAt)
        #expect(recalled.ok, "only successes are ever taught")
    }

    /// SKILL IDS ARE DOTTED and group ids are slashed; the separator must
    /// appear in neither, or a well-formed id would parse into nonsense.
    @Test func theSeparatorCannotOccurInsideTheParts() {
        let id = TotemContextStore.ExemplarAddress.documentID(for: RoutingExemplar(
            query: "q", skillID: "window-management.list-app-windows",
            intent: AmbientIntent.perceive.rawValue, ok: true))

        #expect(id.split(separator: "|").count == 4, "id: \(id)")
        #expect(id.hasPrefix("mary.exemplar|"))
    }

    /// A TOTEM HOLDS MORE THAN ROUTING MEMORY. Anything that is not one of
    /// ours must be ignored rather than half-parsed into a lesson.
    @Test(arguments: [
        "behavior/episode/1234",
        "mary.exemplar|operate",
        "mary.exemplar|operate|skill|not-a-number",
        "somethingelse|operate|skill|1700000000",
        "",
    ])
    func aForeignDocumentTeachesNothing(_ documentID: String) {
        #expect(TotemContextStore.ExemplarAddress.exemplar(
            documentID: documentID, text: "some text") == nil)
    }

    /// The group is per-owner, so two people on one machine never read each
    /// other's routing memory.
    @Test func theGroupIsScopedToItsOwner() {
        let mine = TotemContextStore.exemplarGroup(ownerID: "owner-a")
        let theirs = TotemContextStore.exemplarGroup(ownerID: "owner-b")

        #expect(mine.id != theirs.id)
        #expect(mine.id.hasPrefix("owner-a/"))
    }
}
