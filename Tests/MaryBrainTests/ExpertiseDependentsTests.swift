//
//  ExpertiseDependentsTests.swift
//  MaryBrainTests
//
//  WHAT: The dependency graph read backwards, against the SHIPPED packages.
//  OUT:  AbilityRuntimeSnapshot.expertiseAbilities / applicationID(ofExpertise:)
//  PIN:  Required edges only — an optional support is not somebody's player.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct ExpertiseDependentsTests {

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

    private func record(
        _ package: MaryAbilityPackage, url: URL
    ) -> AbilityPackageRecord {
        AbilityPackageRecord(
            package: package, source: .sourceTree, sourceURL: url,
            validation: .init(), rawData: Data())
    }

    /// The shipped graph: `apple-music` requires `multimedia`, so multimedia's
    /// Skills can land in Apple Music without anyone authoring the edge twice.
    private func shippedSnapshot() throws -> AbilityRuntimeSnapshot? {
        guard let abilities = InstalledPackages.installed() else { return nil }
        let names = ["multimedia", "apple-music"]
        let packages = try names.map { try loadRootPackage($0) }
        let plugins = PluginCompiler.compile(
            packages: packages, nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        return AbilityRuntimeSnapshot(
            records: zip(packages, names).map { package, name in
                record(package, url: abilities.appendingPathComponent("\(name).mary"))
            },
            validation: .init(),
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                observers: MaryAdapterCatalog.observers()),
            plugins: plugins)
    }

    @Test func appleMusicInheritsMultimedia() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        #expect(
            snapshot.expertiseAbilities(extending: AbilityID("multimedia"))
                == [AbilityID("apple-music")])
    }

    @Test func theExpertiseNamesTheApplicationItDrives() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        #expect(
            snapshot.applicationID(ofExpertise: AbilityID("apple-music"))
                == "apple-music")
    }

    /// `apple-music.mary` depends on `window-management` too, but OPTIONALLY.
    /// An optional support must never make an ability look like a player.
    @Test func anOptionalDependencyIsNotInherited() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        #expect(
            snapshot.expertiseAbilities(
                extending: AbilityID("window-management")).isEmpty)
    }

    /// The routing question, asked the way `ExpertiseResolution` asks it: from
    /// the winning Skill rather than from an ability id.
    @Test func controlPlaybacksOwnerHasAPlayer() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        #expect(snapshot.expertiseAbilities(for: skill) == [AbilityID("apple-music")])
    }

    /// THE REPORTED CASE, end to end on the shipped graph: "pause the music"
    /// wins `control_playback`, whose owner is the multimedia DISCIPLINE — and
    /// the reverse lookup still lands it in Apple Music, with nobody having
    /// said "in Apple Music" and no history yet.
    @Test func pausingLandsInAPlayerWithoutBeingToldWhich() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        let verdict = try #require(ExpertiseResolution.resolve(
            for: skill, snapshot: snapshot,
            ledger: ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())))
        #expect(verdict.disciplineID == AbilityID("multimedia"))
        #expect(verdict.chosen?.applicationID == "apple-music")
        // No history yet, so this is the packages' own order, not a habit.
        #expect(verdict.chosen?.standing == .staticPreference)
    }

    /// And once the person has actually used a player, the same call reports
    /// it as THEIR habit rather than a default.
    @Test func usingAPlayerMakesTheChoiceTheirs() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let now = Date()
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        ledger.record(ApplicationHabit(
            disciplineID: AbilityID("multimedia"),
            expertiseID: AbilityID("apple-music"),
            applicationID: "apple-music",
            skillID: "multimedia.play-playlist",
            observedAt: now), now: now)
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        let verdict = try #require(ExpertiseResolution.resolve(
            for: skill, snapshot: snapshot, ledger: ledger, now: now))
        #expect(verdict.chosen?.standing == .habitual)
        #expect(verdict.isHabitual)
    }

    /// The `app` argument the shipped Skill can now carry — without it the
    /// resolved player would have nowhere to go at dispatch.
    @Test func controlPlaybackCanCarryAnApp() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        #expect(skill.skill.modelExposure.parameters.contains { $0.name == "app" })
        // Its required argument is still an enum, so the SHORTCUT still does
        // not fire — the model round is expected, and the rehearsal says so.
        #expect(EmbeddingRouting.confidenceShape(of: skill) == nil)
    }

    /// A SHARED WORD IS NOT A NAME. `apple-music` declares the alias "music"
    /// and so does `multimedia` — so the ordinary mention test reads "pause
    /// the music" as though Apple Music had been named. Honoured, that would
    /// outrank the habit tally on every single turn and a person who moved to
    /// another player would never be followed there.
    @Test func sayingTheMusicDoesNotNameApplePlayer() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        let verdict = try #require(ExpertiseResolution.resolve(
            for: skill, snapshot: snapshot,
            // Exactly what `AmbientIntentGate` hands the turn for this
            // sentence, alias collision and all.
            assertedApplicationIDs: ["apple-music"],
            utterance: "can you pause the music",
            ledger: ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())))
        #expect(
            verdict.chosen?.standing != .asserted,
            "\"the music\" is multimedia's own word, not Apple Music's name")
        #expect(verdict.chosen?.applicationID == "apple-music",
                "it is still the only player installed — just not because it was named")
    }

    /// Saying the player's OWN name still wins outright.
    @Test func sayingApplePlayerByNameStillAsserts() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        let verdict = try #require(ExpertiseResolution.resolve(
            for: skill, snapshot: snapshot,
            assertedApplicationIDs: ["apple-music"],
            utterance: "pause the playback of the music in Apple Music",
            ledger: ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())))
        #expect(verdict.chosen?.standing == .asserted)
    }

    /// And a habit therefore still decides an unnamed turn — the property the
    /// whole feature rests on once a second player exists.
    @Test func aHabitOutranksTheSharedWord() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let now = Date()
        let skill = try #require(
            snapshot.skill(id: SkillID("multimedia.control-playback")))
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        ledger.record(ApplicationHabit(
            disciplineID: AbilityID("multimedia"),
            expertiseID: AbilityID("apple-music"),
            applicationID: "apple-music",
            skillID: "multimedia.play-playlist",
            observedAt: now), now: now)
        let verdict = try #require(ExpertiseResolution.resolve(
            for: skill, snapshot: snapshot,
            assertedApplicationIDs: ["apple-music"],
            utterance: "can you pause the music",
            ledger: ledger, now: now))
        #expect(verdict.chosen?.standing == .habitual,
                "the tally decides, because nothing was actually named")
    }

    /// A Skill owned by the expertise itself already names its application —
    /// there is nothing to resolve, and asking must not walk further.
    @Test func anExpertiseOwnedSkillResolvesNothing() throws {
        guard let snapshot = try shippedSnapshot() else { return }
        let appleMusicSkills = snapshot.skills.filter {
            $0.ability.id == AbilityID("apple-music")
        }
        // apple-music owns no Skills of its own; it contributes a realization.
        #expect(appleMusicSkills.isEmpty)
    }
}
