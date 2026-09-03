//
//  RoutingHabitRecordingTests.swift
//  MaryBrainTests
//
//  WHAT: WHO may teach the router, and what the habit says.
//  PIN:  THE POISONING TEST IS THE POINT OF THIS FILE. Recording used the
//        route's PRE-dispatch intent, so a turn misrouted to `converse` that
//        the model nonetheless executed stored a `converse` positive — which
//        strengthened the very verdict that had closed the shortcut gate. The
//        mistake taught itself, forever, and no test could see it because the
//        row it wrote was well-formed.
//
import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct RoutingHabitRecordingTests {

    // MARK: - What a dispatch proves

    /// A DISPATCH IS NOT CONVERSATION. Whatever the route believed before the
    /// act, the act is the evidence — so `converse` is re-labelled rather than
    /// believed, and the intent index learns the truth instead of the mistake.
    @Test func aConverseRouteThatActedTeachesOperate() {
        #expect(RoutingHabitRecordingContext.recordableIntent(.converse) == .operate)
    }

    /// The intents an embedding may settle are learned as themselves.
    @Test(arguments: [
        AmbientIntent.operate, .compose, .perceive, .ask,
    ])
    func eligibleIntentsAreLearnedAsThemselves(_ intent: AmbientIntent) {
        #expect(RoutingHabitRecordingContext.recordableIntent(intent) == intent)
    }

    /// Deterministic and classifier-owned intents teach NOTHING: no embedding
    /// verdict can ever settle them (`SemanticIntentIndex.eligibleIntents`),
    /// so seeding them would be corpus nothing can read.
    @Test(arguments: [
        AmbientIntent.revise, .halt, .decide, .architect,
    ])
    func classifierOwnedIntentsTeachNothing(_ intent: AmbientIntent) {
        #expect(RoutingHabitRecordingContext.recordableIntent(intent) == nil)
        #expect(RoutingHabitRecordingContext.grant(
            lane: .model, query: "do the thing", route: intent) == nil)
    }

    @Test func anEmptyUtteranceTeachesNothing() {
        #expect(RoutingHabitRecordingContext.grant(
            lane: .model, query: "   ", route: .operate) == nil)
    }

    // MARK: - The end-to-end claim, through the real chokepoint

    /// THE MANDATED TEST. A converse-routed turn that the model nonetheless
    /// dispatched must leave an OPERATE row and no converse row at all.
    @Test func aConverseRoutedDispatchRecordsOperateNotConverse() async {
        let store = RoutingHabitStore()
        let runtime = Self.runtime(effectful: "do_thing")
        runtime.setRoutingHabitStoreForTesting(store)

        let grant = RoutingHabitRecordingContext.grant(
            lane: .model, query: "surface every window for me", route: .converse)
        #expect(grant != nil)
        await Self.underSnapshot(["do_thing"], []) {
            _ = await RoutingHabitRecordingContext.withGrant(grant) {
                await runtime.dispatch(name: "do_thing", argumentsJSON: "{}", runID: "r1")
            }
        }

        #expect(store.count == 1)
        #expect(store.queries(intent: AmbientIntent.operate.rawValue, ok: true)
            == ["surface every window for me"])
        #expect(store.queries(intent: AmbientIntent.converse.rawValue, ok: true).isEmpty,
                "a converse row would strengthen the misclassification that caused it")
    }

    /// NO GRANT, NO LESSON. This is what keeps the runtime's own pre-reads,
    /// the affordance press, the confirm/cancel replay and the accepted-prose
    /// road ("yes please") out of the corpus.
    @Test func anUngrantedDispatchTeachesNothing() async {
        let store = RoutingHabitStore()
        let runtime = Self.runtime(effectful: "do_thing")
        runtime.setRoutingHabitStoreForTesting(store)

        await Self.underSnapshot(["do_thing"], []) {
            _ = await runtime.dispatch(name: "do_thing", argumentsJSON: "{}", runID: "r1")
        }

        #expect(store.count == 0)
    }

    /// ONE LESSON PER LANE. A routine's later steps run under the same
    /// utterance; without the budget each would map those words onto a Skill
    /// the user never named.
    @Test func aLaneTeachesOnceHoweverManySkillsItRuns() async {
        let store = RoutingHabitStore()
        let runtime = Self.runtime(effectful: "do_thing", second: "do_other")
        runtime.setRoutingHabitStoreForTesting(store)

        let grant = RoutingHabitRecordingContext.grant(
            lane: .model, query: "tidy up my desk", route: .operate)
        await Self.underSnapshot(["do_thing", "do_other"], []) {
            await RoutingHabitRecordingContext.withGrant(grant) {
                _ = await runtime.dispatch(name: "do_thing", argumentsJSON: "{}", runID: "r1")
                _ = await runtime.dispatch(name: "do_other", argumentsJSON: "{}", runID: "r2")
            }
        }

        #expect(store.count == 1)
    }

    /// A MODEL LANE MAY NOT TEACH A READ. "Fix the bug in main.swift" reads
    /// the buffer before it edits; learned, that phrasing could later win the
    /// read uniquely and the shortcut would read the file and CLOSE the turn
    /// without doing the work.
    @Test func theModelLaneDoesNotTeachReads() async {
        let store = RoutingHabitStore()
        let runtime = Self.runtime(readOnly: "read_thing")
        runtime.setRoutingHabitStoreForTesting(store)

        let grant = RoutingHabitRecordingContext.grant(
            lane: .model, query: "fix the bug in main", route: .operate)
        await Self.underSnapshot([], ["read_thing"]) {
            _ = await RoutingHabitRecordingContext.withGrant(grant) {
                await runtime.dispatch(name: "read_thing", argumentsJSON: "{}", runID: "r1")
            }
        }

        #expect(store.count == 0)
    }

    /// The confidence lane may: there the embedding picked this Skill from
    /// these very words, so the row only reinforces its own win.
    @Test func theConfidenceLaneMayTeachAReadItAlreadyWon() async {
        let store = RoutingHabitStore()
        let runtime = Self.runtime(readOnly: "read_thing")
        runtime.setRoutingHabitStoreForTesting(store)

        let grant = RoutingHabitRecordingContext.grant(
            lane: .confidence, query: "which windows are up", route: .operate)
        await Self.underSnapshot([], ["read_thing"]) {
            _ = await RoutingHabitRecordingContext.withGrant(grant) {
                await runtime.dispatch(name: "read_thing", argumentsJSON: "{}", runID: "r1")
            }
        }

        #expect(store.queries(skillID: "fixture.read_thing", ok: true)
            == ["which windows are up"])
    }

    /// A FAILURE STILL TEACHES NOTHING — the "bad night pins a centroid" PIN
    /// survives the rewrite.
    @Test func aFailedDispatchTeachesNothing() async {
        let store = RoutingHabitStore()
        let runtime = Self.runtime(failing: "do_thing")
        runtime.setRoutingHabitStoreForTesting(store)

        let grant = RoutingHabitRecordingContext.grant(
            lane: .model, query: "do the thing", route: .operate)
        await Self.underSnapshot(["do_thing"], []) {
            _ = await RoutingHabitRecordingContext.withGrant(grant) {
                await runtime.dispatch(name: "do_thing", argumentsJSON: "{}", runID: "r1")
            }
        }

        #expect(store.count == 0)
    }

    // MARK: - Fixture

    private struct ScriptedAdapter: MaryAdapter {
        let name = "fixture"
        let summary = "A fixture."
        let bindings: [SkillBinding]
        var skillBindings: [SkillBinding] { bindings }
    }

    /// Identity for the fixture skills. `skill(invocationName:)` is what turns
    /// a dispatch into a row, and `isReadOnly` reads the binding behind it —
    /// both need a snapshot, so every runtime call here runs under one.
    private static func underSnapshot(
        _ effectful: [String], _ readOnly: [String], _ body: () async -> Void
    ) async {
        func schema(_ name: String) -> SkillSchema {
            SkillSchema(
                id: SkillID("fixture.\(name)"),
                title: name,
                summary: "Fixture skill.",
                kind: .effectful,
                execution: .init(
                    kind: .binding,
                    bindings: [.init(adapterID: AdapterID("fixture"), operation: name)]),
                modelExposure: .init(invocationName: name))
        }
        let skills = (effectful + readOnly).map(schema)
        let package = MaryAbilityPackage(
            package: .init(
                id: PackageID("tests.habit"),
                version: "1.0.0",
                publisher: "tests",
                summary: "Habit fixture."),
            ability: .init(
                id: AbilityID("fixture-habit"),
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                skills: skills.map(\.id)),
            skills: skills)
        let record = AbilityPackageRecord(
            package: package, source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/habit.mary"),
            validation: .init(), rawData: Data())
        // The roster refuses a Skill no installed adapter publishes, so the
        // fixture manifest is what makes these dispatches actually run.
        let manifest = InstalledAdapterManifest(
            adapterID: AdapterID("fixture"),
            title: "Fixture",
            transport: .native,
            operations: (effectful + readOnly).map {
                InstalledAdapterBinding(adapterID: AdapterID("fixture"), operation: $0)
            })
        let snapshot = AbilityRuntime.Snapshot(
            records: [record], validation: .init(), adapterManifests: [manifest])
        await AbilityTurnContext.$snapshot.withValue(snapshot) { await body() }
    }

    private static func runtime(
        effectful: String? = nil,
        second: String? = nil,
        readOnly: String? = nil,
        failing: String? = nil
    ) -> AbilityRuntime {
        var bindings: [SkillBinding] = []
        for name in [effectful, second].compactMap({ $0 }) {
            bindings.append(SkillBinding(
                name: name, description: "Fixture.", access: .tweak,
                backing: .native { _, _ in SkillOutcome(ok: true, summary: "done") }))
        }
        if let readOnly {
            bindings.append(SkillBinding(
                name: readOnly, description: "Fixture read.", access: .read,
                backing: .native { _, _ in SkillOutcome(ok: true, summary: "read") }))
        }
        if let failing {
            bindings.append(SkillBinding(
                name: failing, description: "Fixture failure.", access: .tweak,
                backing: .native { _, _ in SkillOutcome(ok: false, summary: "nope") }))
        }
        return AbilityRuntime(
            plugins: [ScriptedAdapter(bindings: bindings)],
            world: AmbientWorld(),
            passages: PassageRegistry(),
            containers: ContainerRegistry(),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
    }
}
