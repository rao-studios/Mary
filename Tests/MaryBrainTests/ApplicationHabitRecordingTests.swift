//
//  ApplicationHabitRecordingTests.swift
//  MaryBrainTests
//
//  WHAT: A finished dispatch teaches WHICH PLAYER, through the real chokepoint.
//  OUT:  AbilityRuntime.dispatch → ApplicationHabitLedger
//  PIN:  Only a vouched, landed act votes — the same gate the habit row
//        uses, because a failed act says nothing about where someone works.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct ApplicationHabitRecordingTests {

    private static let discipline = AbilityID("fixture-discipline")
    private static let player = AbilityID("fixture-player")

    /// A discipline owning one transport Skill, plus one player package that
    /// requires it and owns nothing — the multimedia / apple-music shape.
    private static func snapshot() -> AbilityRuntimeSnapshot {
        let skill = SkillSchema(
            id: SkillID("fixture.press"),
            title: "Press",
            summary: "Fixture skill.",
            kind: .effectful,
            execution: .init(
                kind: .binding,
                bindings: [.init(adapterID: AdapterID("fixture"), operation: "press")]),
            modelExposure: .init(invocationName: "press"))
        let disciplinePackage = MaryAbilityPackage(
            package: .init(
                id: PackageID("fixture-discipline"), version: "1.0.0",
                publisher: "tests", summary: "Discipline."),
            ability: .init(
                id: discipline, title: "Fixture Discipline",
                summary: "A discipline.", tint: "#112233",
                skills: [skill.id], paradigm: .discipline),
            skills: [skill])
        let playerPackage = MaryAbilityPackage(
            package: .init(
                id: PackageID("fixture-player"), version: "1.0.0",
                publisher: "tests", summary: "Player."),
            ability: .init(
                id: player, title: "Fixture Player",
                summary: "A player.", tint: "#445566",
                skills: [], paradigm: .applicationExpertise,
                applications: [.init(id: "fixture-app", title: "Fixture App")]),
            skills: [],
            dependencies: [.init(
                packageID: PackageID("fixture-discipline"), minimumVersion: "1.0.0")])
        let records = [disciplinePackage, playerPackage].map { package in
            AbilityPackageRecord(
                package: package, source: .sourceTree,
                sourceURL: URL(fileURLWithPath: "/tmp/\(package.package.id.rawValue).mary"),
                validation: .init(), rawData: Data())
        }
        let manifest = InstalledAdapterManifest(
            adapterID: AdapterID("fixture"), title: "Fixture", transport: .native,
            operations: [InstalledAdapterBinding(
                adapterID: AdapterID("fixture"), operation: "press")])
        return AbilityRuntimeSnapshot(
            records: records, validation: .init(), adapterManifests: [manifest])
    }

    private struct ScriptedAdapter: MaryAdapter {
        let name = "fixture"
        let summary = "A fixture."
        let bindings: [SkillBinding]
        var skillBindings: [SkillBinding] { bindings }
    }

    private static func runtime(outcome: @escaping @Sendable () -> SkillOutcome) -> AbilityRuntime {
        AbilityRuntime(
            plugins: [ScriptedAdapter(bindings: [SkillBinding(
                name: "press", description: "Fixture.", access: .tweak,
                backing: .native { _, _ in outcome() })])],
            world: AmbientWorld(),
            passages: PassageRegistry(),
            containers: ContainerRegistry(),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
    }

    private static func dispatch(
        outcome: @escaping @Sendable () -> SkillOutcome,
        granted: Bool,
        into ledger: ApplicationHabitLedger
    ) async {
        let runtime = Self.runtime(outcome: outcome)
        runtime.setApplicationHabitLedgerForTesting(ledger)
        runtime.setRoutingHabitStoreForTesting(RoutingHabitStore())
        let grant = granted
            ? RoutingHabitRecordingContext.grant(
                lane: .confidence, query: "press it", route: .operate)
            : nil
        await AbilityTurnContext.$snapshot.withValue(Self.snapshot()) {
            _ = await RoutingHabitRecordingContext.withGrant(grant) {
                await runtime.dispatch(
                    name: "press", argumentsJSON: "{}", runID: "habit-1")
            }
        }
    }

    /// THE CLAIM: acting in a player, once, is a vote for that player.
    @Test func alandedActVotesForThePlayerItLandedIn() async {
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        await Self.dispatch(
            outcome: { SkillOutcome(
                ok: true, summary: "done", applicationID: "fixture-app") },
            granted: true, into: ledger)
        #expect(ledger.weights(for: Self.discipline)[Self.player] != nil)
    }

    /// A look that found nothing is not a preference.
    @Test func anEmptyHandedActVotesForNothing() async {
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        await Self.dispatch(
            outcome: { SkillOutcome(
                ok: true, summary: "nothing there", foundNothing: true,
                applicationID: "fixture-app") },
            granted: true, into: ledger)
        #expect(ledger.weights(for: Self.discipline).isEmpty)
    }

    @Test func aFailedActVotesForNothing() async {
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        await Self.dispatch(
            outcome: { SkillOutcome(
                ok: false, summary: "nope", applicationID: "fixture-app") },
            granted: true, into: ledger)
        #expect(ledger.weights(for: Self.discipline).isEmpty)
    }

    /// No lane vouched for these words, so nothing is learned from them —
    /// the runtime's own pre-reads must not become somebody's habit.
    @Test func anUnvouchedActVotesForNothing() async {
        let ledger = ApplicationHabitLedger(memory: EmptyApplicationHabitMemory())
        await Self.dispatch(
            outcome: { SkillOutcome(
                ok: true, summary: "done", applicationID: "fixture-app") },
            granted: false, into: ledger)
        #expect(ledger.weights(for: Self.discipline).isEmpty)
    }
}
