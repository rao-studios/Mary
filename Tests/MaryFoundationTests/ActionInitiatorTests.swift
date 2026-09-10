//
//  ActionInitiatorTests.swift
//  MaryFoundationTests
//
//  WHAT: ActionInitiator's decode tolerance — BehavioralDisposition's own pattern.
//  OUT:  BehavioralActionRecord.initiator
//  PIN:  Absent key reads .model (every record persisted before this field
//        existed); an unrecognized value decodes rather than throws.
//

import Foundation
import Testing
@testable import MaryFoundation
import MaryFoundationTestSupport

@Suite struct ActionInitiatorTests {

    /// A record encoded before `initiator` existed has no such key at all —
    /// this is the actual shape of every already-persisted conversation and
    /// deposited episode, not merely "some field happens to be missing."
    @Test func aRecordWithNoInitiatorDecodesAsModel() throws {
        let data = try JSONEncoder().encode(BehaviorFixtures.typedRecord)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "initiator")
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BehavioralActionRecord.self, from: stripped)
        #expect(decoded.initiator == .model)
    }

    /// A value only a future build could have written decodes to `.unknown`
    /// rather than failing the whole record open — the exact rule
    /// `BehavioralDisposition` already established for this file format.
    @Test func anUnknownInitiatorDecodesRatherThanThrows() throws {
        let data = try JSONEncoder().encode(BehaviorFixtures.typedRecord)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["initiator"] = "somethingFutureBuildsInvented"
        let mutated = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(BehavioralActionRecord.self, from: mutated)
        #expect(decoded.initiator == .unknown)
    }

    /// Every case this build actually writes round-trips through its raw value.
    @Test(arguments: [ActionInitiator.model, .maryRead, .maryAct])
    func everyWrittenCaseRoundTrips(_ initiator: ActionInitiator) throws {
        let data = try JSONEncoder().encode(initiator)
        let decoded = try JSONDecoder().decode(ActionInitiator.self, from: data)
        #expect(decoded == initiator)
    }
}
