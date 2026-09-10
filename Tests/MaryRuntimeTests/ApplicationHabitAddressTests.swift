//
//  ApplicationHabitAddressTests.swift
//  MaryRuntimeTests
//
//  WHAT: Habits are addressable, classifiable, and survive the round trip.
//  PIN:  A prefix that is not in the family tables shows up in the Threads pane
//        as "Unrecognized" no matter what it holds — and a ledger that cannot
//        be decoded looks exactly like a fresh install, silently.
//
import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryRuntime

@Suite struct ApplicationHabitAddressTests {

    @Test func theHabitGroupIsFiledUnderPersonal() {
        let group = ThreadMemoryTopology.applicationHabitGroup(ownerID: "owner")
        let classification = ThreadAddressClassifier.classifyGroup(id: group.id)
        #expect(classification.family == .applicationHabitGroup)
        #expect(classification.lane == .personal)
        #expect(classification.isSewnOwned == false)
    }

    @Test func theLedgerDocumentIsFiledUnderPersonal() {
        let id = ThreadMemoryTopology.applicationHabitLedgerDocumentID(
            discipline: "multimedia", ownerID: "owner")
        let classification = ThreadAddressClassifier.classifyDocument(id: id)
        #expect(classification.family == .applicationHabitLedger)
        #expect(classification.lane == .personal)
    }

    /// One document per discipline, per owner — a shared address would let one
    /// person's players overwrite another's, and multimedia overwrite writing.
    @Test func eachOwnerAndDisciplineGetsItsOwnDocument() {
        let a = ThreadMemoryTopology.applicationHabitLedgerDocumentID(
            discipline: "multimedia", ownerID: "owner")
        let b = ThreadMemoryTopology.applicationHabitLedgerDocumentID(
            discipline: "writing", ownerID: "owner")
        let c = ThreadMemoryTopology.applicationHabitLedgerDocumentID(
            discipline: "multimedia", ownerID: "someone-else")
        #expect(a != b)
        #expect(a != c)
        // Stable across calls, or a restore would never find what a deposit wrote.
        #expect(a == ThreadMemoryTopology.applicationHabitLedgerDocumentID(
            discipline: "multimedia", ownerID: "owner"))
    }

    /// The ledger travels as JSON in the document body; if this round trip
    /// breaks, every restore returns empty and the ranking silently resets.
    @Test func aLedgerSurvivesTheRoundTripThroughItsBody() throws {
        let rows = [
            ApplicationHabit(
                disciplineID: AbilityID("multimedia"),
                expertiseID: AbilityID("apple-music"),
                applicationID: "apple-music",
                skillID: "multimedia.control-playback",
                observedAt: Date(timeIntervalSince1970: 1_700_000_000)),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            [ApplicationHabit].self, from: try encoder.encode(rows))
        #expect(decoded == rows)
    }
}
