//
//  MultimediaReachabilityTests.swift
//  MaryBrainTests
//
//  WHAT: Shipped multimedia Skills stay declared; catalog stays ungated.
//  OUT:  multimedia.mary
//  PIN:  Offer is embedding affinity (EmbeddingRoutingTests), not utteranceToken trees.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct MultimediaReachabilityTests {

    /// THE CATALOG SKILLS KEEP THEIR UNCONDITIONAL REACH. Pinned as an
    /// assertion rather than left as an absence, because "nobody got around to
    /// it" and "authoring one here would be a regression" look identical in a
    /// package that still loads.
    @Test func theCatalogSkillsStayUnconditional() throws {
        guard InstalledPackages.installed() != nil else { return }
        let skills = try mediaSkills()

        for id: SkillID in ["multimedia.play-music", "multimedia.search-music"] {
            let skill = try #require(skills[id])
            #expect(
                skill.routing.eligibility == nil,
                "\(id) reaches a web endpoint with no player; an eligibility here only removes reach")
        }
    }

    @Test func theNewPlaylistSkillsAreDeclaredAndExposed() throws {
        guard InstalledPackages.installed() != nil else { return }
        let package = try loadRootPackage("multimedia")
        let skills = try mediaSkills()

        for id: SkillID in ["multimedia.find-playlist", "multimedia.shuffle-playlist"] {
            #expect(package.ability.skills.contains(id), "\(id) is not listed by the Ability")
            let skill = try #require(skills[id])
            #expect(skill.modelExposure.enabled)
            #expect(skill.modelExposure.invocationName != nil)
            #expect(!skill.requirements.capabilities.isEmpty)
        }
    }

    private func mediaSkills() throws -> [SkillID: SkillSchema] {
        Dictionary(
            uniqueKeysWithValues: try loadRootPackage("multimedia").skills.map { ($0.id, $0) })
    }

    private func loadRootPackage(_ name: String) throws -> MaryAbilityPackage {
        guard let abilities = InstalledPackages.installed() else {
            throw CocoaError(.fileNoSuchFile)
        }
        let candidate = abilities.appendingPathComponent("\(name).mary")
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try AbilityPackageCodec.load(from: candidate)
    }
}
