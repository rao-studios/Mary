//
//  AbilityTotemLaneTests.swift
//  MaryFoundationTests
//
//  Application Totem is gone. Ability is the only craft lane; `"application"`
//  on the wire is a one-way alias, not a case. Projection schemas do not
//  name lanes — filing is derived from paradigm and required discipline
//  dependencies.
//

import Foundation
import Testing
@testable import MaryFoundation
import MaryFoundationTestSupport

@Suite struct AbilityTotemLaneTests {

    @Test func theLanesAreAbilityAndPersonal() {
        #expect(TotemLane.allCases == [.ability, .personal])
        #expect(TotemLane.ability.rawValue == "ability")
        #expect(TotemLane.personal.rawValue == "personal")
    }

    @Test func encodingNeverEmitsApplication() throws {
        let data = try JSONEncoder().encode(TotemLane.ability)
        #expect(String(data: data, encoding: .utf8) == "\"ability\"")
    }

    @Test func decodingApplicationIsAbility() throws {
        let data = Data("\"application\"".utf8)
        #expect(try JSONDecoder().decode(TotemLane.self, from: data) == .ability)
        #expect(TotemLane(admitting: "application") == .ability)
        #expect(TotemLane(rawValue: "application") == nil)
    }

    @Test func aProjectionDoesNotAuthorLanes() throws {
        let schema = TotemProjectionSchema(
            id: "tests.receipts",
            purpose: .receipt,
            persistence: .durable)
        let encoded = try JSONEncoder().encode(schema)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        #expect(object?["lanes"] == nil)
        let decoded = try JSONDecoder().decode(TotemProjectionSchema.self, from: encoded)
        #expect(decoded.persistence == .durable)
        #expect(decoded.purpose == .receipt)
    }

    @Test func leftoverProjectionLanesAreIgnored() throws {
        let json = """
        {"id":"legacy.receipts","version":"1.0.0","purpose":"receipt",\
        "skills":[],"lanes":["application","personal"],"persistence":"durable",\
        "include":[],"exclude":[],"redactContent":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TotemProjectionSchema.self, from: json)
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
        let targets = expertise.abilityTotemTargets { id in
            id.rawValue == "tests.minimal" ? .discipline : .systemControl
        }
        #expect(targets == [
            AbilityTotemTarget(abilityID: "tests.editor", paradigm: .applicationExpertise),
            AbilityTotemTarget(abilityID: "tests.minimal", paradigm: .discipline),
        ])
        #expect(expertise.extendedDisciplines == ["tests.minimal"])
    }

    @Test func aDisciplineDoesNotFanOutThroughSupportAbilities() {
        let discipline = PackageFixtures.minimalDiscipline
        let targets = discipline.abilityTotemTargets { _ in .systemControl }
        #expect(targets == [
            AbilityTotemTarget(abilityID: "tests.minimal", paradigm: .discipline)
        ])
        #expect(discipline.extendedDisciplines.isEmpty)
    }
}
