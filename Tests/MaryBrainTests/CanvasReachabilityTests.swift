//
//  CanvasReachabilityTests.swift
//  MaryBrainTests
//
//  WHAT: The canvas package declares what the compiled adapter binds, and
//        stays the app-free supporting Ability it was written as.
//  OUT:  canvas.mary
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct CanvasReachabilityTests {

    @Test func theCanvasSkillsAreDeclaredAndBound() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("canvas")
        let skills = Dictionary(uniqueKeysWithValues: package.skills.map { ($0.id, $0) })
        let bound = Set(CanvasPlugin().skillBindings.map(\.name))

        for (id, operation): (SkillID, String) in [("canvas.present", "present_page"), ("canvas.dismiss", "dismiss_page")] {
            #expect(package.ability.skills.contains(id), "\(id) is not listed by the Ability")
            let skill = try #require(skills[id])
            #expect(skill.modelExposure.enabled)
            #expect(skill.modelExposure.invocationName == operation)
            #expect(skill.execution.bindings.map(\.operation) == [operation])
            #expect(skill.execution.bindings.first?.adapterID.rawValue == CanvasPlugin.adapterID)
            #expect(bound.contains(operation), "\(operation) is not a compiled binding")
        }
        #expect(package.paradigm == .systemControl)
        #expect(package.applicationAffinities.isEmpty, "the canvas names no application")
    }

    /// The model's page is composed, so the Skill can never take the no-model lane.
    @Test func presentingAPageIsAComposedAct() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("canvas")
        let present = try #require(package.skills.first { $0.id == "canvas.present" })
        let html = try #require(present.modelExposure.parameters.first { $0.name == "html" })
        #expect(html.required)
        #expect(html.requiresComposition)
        #expect(present.usesStage)
    }

    @Test func everyFixtureNamesItsOwnSkill() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("canvas")
        let own = Set(package.skills.map(\.id))
        #expect(!package.fixtures.isEmpty)
        for fixture in package.fixtures {
            let expected = try #require(fixture.expectedSkill)
            #expect(own.contains(expected), "\(fixture.id) names \(expected.rawValue)")
        }
    }

    private func loadRootPackage(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(from: abilities.appendingPathComponent("\(name).mary"))
    }
}
