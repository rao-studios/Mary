//
//  MultimediaReachabilityTests.swift
//  MaryBrainTests
//
//  WHAT: Media Skills keep a targetClass arm so utterance widening is not a narrowing.
//  OUT:  AbilityRoutingEvaluator on multimedia.mary
//  PIN:  play-music / search-music stay un-gated — they have no player class
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct MultimediaReachabilityTests {

    // MARK: - The narrowing guard

    /// THE ONE THAT MATTERS. A player is frontmost and the user says something
    /// carrying none of the authored tokens. Before the utterance arms existed
    /// this was admitted because the Skill had no policy at all; it must still
    /// be admitted now, on the target-class arm alone.
    @Test func everyPlayerBoundSkillSurvivesAnUtteranceMatchingNoWords() throws {
        guard InstalledPackages.installed() != nil else { return }
        let skills = try mediaSkills()
        let atThePlayerSayingNothingSpecific = AbilityRoutingContext(
            utterance: "do that thing again",
            targetClasses: ["media-player"])

        for id in Self.playerBound {
            let skill = try #require(skills[id], "\(id) is missing from multimedia.mary")
            #expect(
                AbilityRoutingEvaluator.isEligible(
                    skill.routing, in: atThePlayerSayingNothingSpecific),
                "\(id) stopped being reachable from a player with no matching words")
        }
    }

    /// THE FIRST ARM, named rather than implied. If a future edit drops the
    /// target-class child while keeping the utterance ones, the test above
    /// still passes for any Skill whose words happen to appear in its fixture
    /// — this one fails for the right reason instead.
    @Test func everyPlayerBoundSkillKeepsItsTargetClassArm() throws {
        guard InstalledPackages.installed() != nil else { return }
        let skills = try mediaSkills()

        for id in Self.playerBound {
            let skill = try #require(skills[id])
            let eligibility = try #require(
                skill.routing.eligibility, "\(id) lost its eligibility entirely")
            #expect(eligibility.kind == .any, "\(id)'s eligibility must stay an `any` tree")
            #expect(
                eligibility.children.contains {
                    $0.kind == .targetClass && $0.value == "media-player"
                },
                "\(id) dropped the arm that reproduces its original admission")
        }
    }

    // MARK: - The widening

    /// The point of the exercise: a playlist request reaches the playlist
    /// Skills through words alone, with no player resolved yet — which is the
    /// case a bare target-class policy could never have carried.
    @Test func playlistWordsReachThePlaylistSkillsWithNoPlayerResolved() throws {
        guard InstalledPackages.installed() != nil else { return }
        let skills = try mediaSkills()

        let cases: [(SkillID, String)] = [
            ("multimedia.play-playlist", "put on my running mix"),
            ("multimedia.play-playlist", "play my Workout playlist"),
            ("multimedia.list-playlists", "what playlists do I have"),
            ("multimedia.find-playlist", "do I have a playlist for dinner"),
            ("multimedia.shuffle-playlist", "shuffle my Dinner Office playlist"),
            ("multimedia.shuffle-playlist", "play my running mix on shuffle"),
        ]
        for (id, utterance) in cases {
            let skill = try #require(skills[id])
            let spokenWithNothingOnScreen = AbilityRoutingContext(utterance: utterance)
            #expect(
                AbilityRoutingEvaluator.isEligible(
                    skill.routing, in: spokenWithNothingOnScreen),
                "\(id) did not admit \"\(utterance)\"")
        }
    }

    /// THE CATALOG SKILLS KEEP THEIR UNCONDITIONAL REACH. Pinned as an
    /// assertion rather than left as an absence, because "nobody got around to
    /// it" and "authoring one here would be a regression" look identical in the
    /// package and only one of them is true.
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

    // MARK: - The new Skills exist end to end

    /// A Skill the Ability does not list is an orphan the graph validator
    /// refuses, and a Skill with no `modelExposure` name never reaches the
    /// model — both of which are silent in a package that still loads.
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

    // MARK: - Helpers

    /// The Skills whose bindings already declared `media-player`, and therefore
    /// the only ones an `any(targetClass, …)` tree can carry without loss.
    private static let playerBound: [SkillID] = [
        "multimedia.now-playing",
        "multimedia.control-playback",
        "multimedia.list-playlists",
        "multimedia.find-playlist",
        "multimedia.play-playlist",
        "multimedia.shuffle-playlist",
    ]

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
