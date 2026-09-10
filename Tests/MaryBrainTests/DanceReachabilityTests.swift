//
//  DanceReachabilityTests.swift
//  MaryBrainTests
//
//  WHAT: The dance package declares what the compiled adapter binds, leans on
//        the canvas, and keeps its Skills dispatchable without a model round.
//  OUT:  dance.mary
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct DanceReachabilityTests {

    @Test func theDanceSkillsAreDeclaredAndBound() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("dance")
        let skills = Dictionary(uniqueKeysWithValues: package.skills.map { ($0.id, $0) })
        let bound = Set(DancePlugin(compose: UnavailableDanceComposer()).skillBindings.map(\.name))

        for (id, operation): (SkillID, String) in [
            ("dance.start", "start_dance"), ("dance.mood", "show_mood"), ("dance.stop", "stop_dance"),
        ] {
            #expect(package.ability.skills.contains(id), "\(id) is not listed by the Ability")
            let skill = try #require(skills[id])
            #expect(skill.modelExposure.enabled)
            #expect(skill.modelExposure.invocationName == operation)
            #expect(skill.execution.bindings.first?.adapterID.rawValue == DancePlugin.adapterID)
            #expect(bound.contains(operation), "\(operation) is not a compiled binding")
            // NO REQUIRED ARGUMENT, so the confidence lane can dispatch it whole.
            #expect(skill.modelExposure.parameters.allSatisfy { !$0.required }, "\(id) needs an argument")
        }
        #expect(package.paradigm == .systemControl)
        #expect(package.applicationAffinities.isEmpty)
    }

    @Test func theDanceLeansOnTheCanvas() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("dance")
        #expect(package.dependencies.contains { $0.packageID.rawValue == "canvas" && !$0.optional })
        #expect(package.ability.operatingPolicy.defaultSupportingAbilities == [.canvas])
        for skill in package.skills where skill.id != "dance.stop" {
            #expect(skill.requirements.capabilities.contains("canvas.present"), "\(skill.id) does not need the canvas")
            #expect(skill.usesStage, "\(skill.id) shows a window and must stage")
        }
    }

    @Test func everyFixtureNamesItsOwnSkill() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("dance")
        let own = Set(package.skills.map(\.id))
        #expect(package.fixtures.count >= 15)
        for fixture in package.fixtures {
            let expected = try #require(fixture.expectedSkill)
            #expect(own.contains(expected), "\(fixture.id) names \(expected.rawValue)")
        }
        // A greeting stays small talk: the bare converse seed is never ours.
        let seeds = package.ability.triggers.intentSeeds.values.flatMap { $0 }
        #expect(!seeds.contains("how are you"))
    }

    private func loadRootPackage(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(from: abilities.appendingPathComponent("\(name).mary"))
    }
}
