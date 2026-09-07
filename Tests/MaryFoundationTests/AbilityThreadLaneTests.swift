//
//  AbilityThreadLaneTests.swift
//  MaryFoundationTests
//
//  WHAT: Ability is the only craft Thread lane; filing is derived, not declared.
//  OUT:  ThreadLane + projection filing
//

import Foundation
import Testing
@testable import MaryFoundation
import MaryFoundationTestSupport

@Suite struct AbilityThreadLaneTests {

    @Test func theLanesAreAbilityAndPersonal() {
        #expect(ThreadLane.allCases == [.ability, .personal])
        #expect(ThreadLane.ability.rawValue == "ability")
        #expect(ThreadLane.personal.rawValue == "personal")
    }

    @Test func encodingNeverEmitsApplication() throws {
        let data = try JSONEncoder().encode(ThreadLane.ability)
        #expect(String(data: data, encoding: .utf8) == "\"ability\"")
    }

    @Test func decodingApplicationIsRejected() {
        let data = Data("\"application\"".utf8)
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ThreadLane.self, from: data)
        }
        #expect(ThreadLane(rawValue: "application") == nil)
    }

    @Test func aProjectionDoesNotAuthorLanes() throws {
        let schema = ThreadProjectionSchema(
            id: "tests.receipts",
            purpose: .receipt,
            persistence: .durable)
        let encoded = try JSONEncoder().encode(schema)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["lanes"] == nil)
        let decoded = try JSONDecoder().decode(ThreadProjectionSchema.self, from: encoded)
        #expect(decoded.persistence == .durable)
        #expect(decoded.purpose == .receipt)
    }

    @Test func leftoverProjectionLanesAreIgnored() throws {
        let json = """
        {"id":"legacy.receipts","version":"1.0.0","purpose":"receipt",\
        "skills":[],"lanes":["application","personal"],"persistence":"durable",\
        "include":[],"exclude":[],"redactContent":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ThreadProjectionSchema.self, from: json)
        #expect(decoded.persistence == .durable)
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(decoded)) as? [String: Any]
        #expect(object?["lanes"] == nil)
    }

    @Test func expertiseIndexesTheDisciplinesItDependsOn() {
        var expertise = PackageFixtures.applicationExpertise
        expertise.dependencies = [
            .init(packageID: "tests.minimal", minimumVersion: "1.0.0"),
            .init(packageID: "window-management", minimumVersion: "1.0.0", optional: true)
        ]
        let targets = expertise.abilityThreadTargets { id in
            id.rawValue == "tests.minimal" ? .discipline : .systemControl
        }
        #expect(targets == [
            AbilityThreadTarget(abilityID: "tests.editor", paradigm: .applicationExpertise),
            AbilityThreadTarget(abilityID: "tests.minimal", paradigm: .discipline),
        ])
        #expect(expertise.extendedDisciplines == ["tests.minimal"])
    }

    @Test func aDisciplineDoesNotFanOutThroughSupportAbilities() {
        let discipline = PackageFixtures.minimalDiscipline
        let targets = discipline.abilityThreadTargets { _ in .systemControl }
        #expect(targets == [
            AbilityThreadTarget(abilityID: "tests.minimal", paradigm: .discipline)
        ])
        #expect(discipline.extendedDisciplines.isEmpty)
    }
}
