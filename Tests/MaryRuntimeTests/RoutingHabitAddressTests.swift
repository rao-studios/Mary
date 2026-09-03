//
//  RoutingHabitAddressTests.swift
//  MaryRuntimeTests
//
//  WHAT: The document id IS the label.
//  PIN:  A totem search returns documentID, text and score — and NOT the
//        `metadata` an index item accepts. So which Skill and which intent a
//        recalled habit teaches has to be readable from its id alone. If this
//        round trip breaks, routing memory silently returns nothing: every hit
//        fails to parse and the loop looks merely empty.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryRuntime

@Suite struct RoutingHabitAddressTests {

    @Test func aLessonSurvivesTheRoundTripThroughItsDocumentID() throws {
        let stored = RoutingHabit(
            query: "put the running mix on",
            skillID: "multimedia.play-playlist",
            intent: AmbientIntent.operate.rawValue,
            ok: true,
            storedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let id = TotemContextStore.RoutingHabitAddress.documentID(for: stored)
        let recalled = try #require(TotemContextStore.RoutingHabitAddress.habit(
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
        let id = TotemContextStore.RoutingHabitAddress.documentID(for: RoutingHabit(
            query: "q", skillID: "window-management.list-app-windows",
            intent: AmbientIntent.perceive.rawValue, ok: true))

        #expect(id.hasPrefix("mary-routing-"), "id: \(id)")
        #expect(id.dropFirst("mary-routing-".count).split(separator: "|").count == 3, "id: \(id)")
    }

    /// A TOTEM HOLDS MORE THAN ROUTING MEMORY. Anything that is not one of
    /// ours must be ignored rather than half-parsed into a habit.
    @Test(arguments: [
        "mary-behavior-1234",
        "mary-routing-operate",
        "mary-routing-operate|skill|not-a-number",
        "somethingelse-operate|skill|1700000000",
        "",
    ])
    func aForeignDocumentTeachesNothing(_ documentID: String) {
        #expect(TotemContextStore.RoutingHabitAddress.habit(
            documentID: documentID, text: "some text") == nil)
    }

    /// THE PANE HAS TO RECOGNISE THEM. `TotemAddressClassifier` reads families
    /// from prefixes alone, so an address off the house pattern lands in
    /// "Unrecognized" however well-formed it is — which is exactly where these
    /// went before the prefix was fixed.
    @Test func routingAddressesClassifyOntoThePersonalLane() {
        let group = TotemAddressClassifier.classifyGroup(
            id: TotemContextStore.routingHabitGroup(ownerID: "owner-a").id)
        #expect(group.family == .routingGroup)
        #expect(group.lane == .personal)
        #expect(!group.isSeerOwned)

        let document = TotemAddressClassifier.classifyDocument(
            id: TotemContextStore.RoutingHabitAddress.documentID(for: RoutingHabit(
                query: "q", skillID: "multimedia.play-playlist",
                intent: AmbientIntent.operate.rawValue, ok: true)))
        #expect(document.family == .routingHabit)
        #expect(document.lane == .personal)
    }

    /// The group is per-owner, so two people on one machine never read each
    /// other's routing memory.
    @Test func theGroupIsScopedToItsOwner() {
        let mine = TotemContextStore.routingHabitGroup(ownerID: "owner-a")
        let theirs = TotemContextStore.routingHabitGroup(ownerID: "owner-b")

        #expect(mine.id != theirs.id)
        #expect(mine.id == "mary-routing-owner-a")
    }
}
