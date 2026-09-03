//
//  ExpertiseResolutionTests.swift
//  MaryBrainTests
//
//  WHAT: Which player a discipline's Skill lands in, and why.
//  OUT:  ExpertiseResolution.resolve / .habit
//  PIN:  Words beat habit; habit beats the packages' declared order. A cold
//        start still ACTS — with two players and no history the declared
//        preference decides rather than the turn stalling.
//

import Foundation
import Testing
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct ExpertiseResolutionTests {

    private let multimedia = AbilityID("multimedia")
    private let appleMusic = AbilityID("apple-music")
    private let spotify = AbilityID("spotify")

    // MARK: - A two-player world

    private func disciplinePackage() -> MaryAbilityPackage {
        let skill = SkillSchema(
            id: SkillID("multimedia.control-playback"),
            title: "Control Playback",
            summary: "Fixture transport skill.",
            kind: .effectful,
            execution: .init(
                kind: .binding,
                bindings: [.init(
                    adapterID: AdapterID("fixture"), operation: "control_playback")]),
            modelExposure: .init(invocationName: "control_playback"))
        return MaryAbilityPackage(
            package: .init(
                id: "multimedia", version: "1.0.0",
                publisher: "tests", summary: "Discipline fixture."),
            ability: .init(
                id: multimedia,
                title: "Multimedia",
                summary: "A discipline, nobody's application.",
                tint: "#112233",
                skills: [skill.id],
                paradigm: .discipline),
            skills: [skill])
    }

    /// An application-expertise package: owns no Skills, requires the
    /// discipline, and names the one application it drives — apple-music's
    /// exact shape.
    private func playerPackage(
        _ abilityID: AbilityID, preference: Int
    ) -> MaryAbilityPackage {
        MaryAbilityPackage(
            package: .init(
                id: PackageID(abilityID.rawValue), version: "1.0.0",
                publisher: "tests", summary: "Player fixture."),
            ability: .init(
                id: abilityID,
                title: abilityID.rawValue.capitalized,
                summary: "A player.",
                tint: "#445566",
                skills: [],
                routing: .init(preference: preference),
                paradigm: .applicationExpertise,
                applications: [.init(
                    id: abilityID.rawValue,
                    title: abilityID.rawValue.capitalized)]),
            skills: [],
            dependencies: [.init(packageID: "multimedia", minimumVersion: "1.0.0")])
    }

    private func snapshot(players: [MaryAbilityPackage]) -> AbilityRuntimeSnapshot {
        let packages = [disciplinePackage()] + players
        let records = packages.map { package in
            AbilityPackageRecord(
                package: package, source: .sourceTree,
                sourceURL: URL(fileURLWithPath: "/tmp/\(package.package.id.rawValue).mary"),
                validation: .init(), rawData: Data())
        }
        let manifest = InstalledAdapterManifest(
            adapterID: AdapterID("fixture"),
            title: "Fixture",
            transport: .native,
            operations: [InstalledAdapterBinding(
                adapterID: AdapterID("fixture"), operation: "control_playback")])
        return AbilityRuntimeSnapshot(
            records: records, validation: .init(), adapterManifests: [manifest])
    }

    private func transportSkill(
        _ snapshot: AbilityRuntimeSnapshot
    ) throws -> AbilityRuntimeSkill {
        try #require(snapshot.skill(id: SkillID("multimedia.control-playback")))
    }

    private func habit(
        _ expertise: AbilityID, at date: Date
    ) -> ApplicationHabit {
        ApplicationHabit(
            disciplineID: multimedia, expertiseID: expertise,
            applicationID: expertise.rawValue,
            skillID: "multimedia.control-playback", observedAt: date)
    }

    // MARK: - Cold start

    /// Two players, no history: Mary still acts, on the packages' own order.
    @Test func withNoHistoryTheDeclaredPreferenceDecides() throws {
        let snapshot = snapshot(players: [
            playerPackage(appleMusic, preference: 120),
            playerPackage(spotify, preference: 90),
        ])
        let verdict = try #require(ExpertiseResolution.resolve(
            for: try transportSkill(snapshot), snapshot: snapshot,
            ledger: ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())))
        #expect(verdict.chosen?.expertiseID == appleMusic)
        #expect(verdict.chosen?.standing == .staticPreference)
        #expect(verdict.isHabitual == false)
    }

    @Test func oneInstalledPlayerIsTheAnswer() throws {
        let snapshot = snapshot(players: [playerPackage(appleMusic, preference: 120)])
        let verdict = try #require(ExpertiseResolution.resolve(
            for: try transportSkill(snapshot), snapshot: snapshot,
            ledger: ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())))
        #expect(verdict.candidates.count == 1)
        #expect(verdict.chosen?.expertiseID == appleMusic)
    }

    // MARK: - Habit

    @Test func theHabitualPlayerWinsOverTheDeclaredOrder() throws {
        let now = Date()
        let snapshot = snapshot(players: [
            playerPackage(appleMusic, preference: 120),
            playerPackage(spotify, preference: 90),
        ])
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        for _ in 0..<3 { ledger.record(habit(spotify, at: now), now: now) }
        let verdict = try #require(ExpertiseResolution.resolve(
            for: try transportSkill(snapshot), snapshot: snapshot,
            ledger: ledger, now: now))
        #expect(verdict.chosen?.expertiseID == spotify)
        #expect(verdict.chosen?.standing == .habitual)
        #expect(verdict.isHabitual)
        #expect(verdict.candidates.first?.expertiseID == spotify)
        #expect(verdict.candidates.last?.standing == .staticPreference)
    }

    /// Used exactly as often is a genuine ambiguity — no habit is claimed and
    /// the declared order settles it, rather than float noise deciding.
    @Test func anEvenlyUsedPairClaimsNoHabit() throws {
        let now = Date()
        let snapshot = snapshot(players: [
            playerPackage(appleMusic, preference: 120),
            playerPackage(spotify, preference: 90),
        ])
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        ledger.record(habit(spotify, at: now), now: now)
        ledger.record(habit(appleMusic, at: now), now: now)
        let verdict = try #require(ExpertiseResolution.resolve(
            for: try transportSkill(snapshot), snapshot: snapshot,
            ledger: ledger, now: now))
        #expect(verdict.isHabitual == false)
        #expect(verdict.chosen?.expertiseID == appleMusic, "declared order settles a tie")
    }

    // MARK: - Words

    @Test func namingAPlayerBeatsTheHabit() throws {
        let now = Date()
        let snapshot = snapshot(players: [
            playerPackage(appleMusic, preference: 120),
            playerPackage(spotify, preference: 90),
        ])
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        for _ in 0..<5 { ledger.record(habit(spotify, at: now), now: now) }
        let verdict = try #require(ExpertiseResolution.resolve(
            for: try transportSkill(snapshot), snapshot: snapshot,
            assertedApplicationIDs: ["apple-music"],
            ledger: ledger, now: now))
        #expect(verdict.chosen?.expertiseID == appleMusic)
        #expect(verdict.chosen?.standing == .asserted)
        #expect(verdict.candidates.first?.expertiseID == appleMusic, "the named one leads the tier")
    }

    // MARK: - Nothing to resolve

    @Test func aDisciplineNobodyExtendsResolvesNothing() throws {
        let snapshot = snapshot(players: [])
        #expect(ExpertiseResolution.resolve(
            for: try transportSkill(snapshot), snapshot: snapshot) == nil)
    }

    // MARK: - What a dispatch proves

    @Test func anOutcomeThatNamesItsApplicationTeachesAHabit() throws {
        let snapshot = snapshot(players: [
            playerPackage(appleMusic, preference: 120),
            playerPackage(spotify, preference: 90),
        ])
        let habit = try #require(ExpertiseResolution.habit(
            proving: try transportSkill(snapshot),
            outcome: SkillOutcome(ok: true, summary: "Paused.", applicationID: "spotify"),
            providerApplicationID: nil,
            snapshot: snapshot))
        #expect(habit.expertiseID == spotify)
        #expect(habit.disciplineID == multimedia)
    }

    /// An application nothing in the graph inherits teaches nothing — a habit
    /// has to name a player Mary could later choose.
    @Test func anUnknownApplicationTeachesNothing() throws {
        let snapshot = snapshot(players: [playerPackage(appleMusic, preference: 120)])
        #expect(ExpertiseResolution.habit(
            proving: try transportSkill(snapshot),
            outcome: SkillOutcome(ok: true, summary: "Paused.", applicationID: "vlc"),
            providerApplicationID: nil,
            snapshot: snapshot) == nil)
    }

    /// Nothing said which application answered, so nothing is learned — an
    /// `app` argument alone is aim, not proof.
    @Test func anUnattributedOutcomeTeachesNothing() throws {
        let snapshot = snapshot(players: [playerPackage(appleMusic, preference: 120)])
        #expect(ExpertiseResolution.habit(
            proving: try transportSkill(snapshot),
            outcome: SkillOutcome(ok: true, summary: "Paused."),
            providerApplicationID: nil,
            snapshot: snapshot) == nil)
    }
}
