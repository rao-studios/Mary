import Foundation
import Testing
@testable import MaryBrain
@testable import MaryPlugin
@testable import MaryAmbient

/// Pins the placement-clause mechanism that closes "the model drafts a
/// reword and never places it" (`[Corpus N]`) — the same asymmetry
/// `[Corpus M]`'s neighbor bug fixed for Scrivener's perception, one level
/// up the stack. `.composeDraft` already appends a concrete delivery clause
/// once it knows a destination; `.reviseSelection` did not, so a real
/// "reword this" turn drafted a replacement and spoke it, and the document
/// was never touched. These tests dispatch `revise_selection` for real
/// through `AbilityRuntime.dispatch`, exactly like
/// `CapabilityConstraintExecutionTests.cognitivePrimitiveRejectsOversized...`
/// does for `compose_draft`, and pin both branches of the new clause.
@Suite struct CognitivePrimitivePlacementTests {

    @Test func reviseSelectionAppendsPlacementClauseWhenASelectionIsRouted() async {
        let now = Date()
        let ambient = AmbientContextStore()

        let attention = AmbientAttention(
            tier: .selection,
            world: .applications,
            applicationID: "com.apple.TextEdit",
            selectedText: "the quick brown fox",
            selectionEditability: .editable,
            selectionSourceEvidence: .exactElement,
            capturedAt: now)
        ambient.noteRoute(AmbientRoute(
            intent: .revise,
            decidedBy: .editIntent,
            attention: attention,
            selectionDefinesTurn: true,
            writingTarget: .selection))
        ambient.recordSelection(
            AmbientSelectionHandoff(
                world: .applications,
                applicationID: "com.apple.TextEdit",
                processID: 4242,
                text: "the quick brown fox",
                editability: .editable,
                capturedAt: now,
                channel: .accessibilityNotification,
                sourceEvidence: .exactElement),
            at: now)

        // The predicate the new clause gates on is exactly the one
        // `type_at_cursor(mode: "replace_selection")` itself checks at
        // dispatch — proving the fixture actually models "this call would
        // succeed", not just "some route exists".
        #expect(ambient.routedSelectionHandoff(requiringWritingTarget: true) != nil)

        let outcome = await dispatchReviseSelection(ambient: ambient)

        #expect(outcome.ok)
        #expect(outcome.summary.contains(
            "call type_at_cursor with mode: \"replace_selection\""))
        #expect(outcome.summary.contains("in this same response"))
        #expect(outcome.summary.contains(
            "never claim the selection was replaced until that call returns ok"))
    }

    @Test func reviseSelectionOmitsPlacementClauseWithNoRoutedSelection() async {
        // A bare, unrouted store: no route, no handoff — the honest-fallback
        // shape `.composeDraft` already has for "no destination was asked
        // for". The base activation text must still be self-consistent on
        // its own, with no dangling instruction to call a Skill that
        // dispatch would immediately refuse.
        let ambient = AmbientContextStore()
        #expect(ambient.routedSelectionHandoff(requiringWritingTarget: true) == nil)

        let outcome = await dispatchReviseSelection(ambient: ambient)

        #expect(outcome.ok)
        #expect(!outcome.summary.contains("type_at_cursor"))
        #expect(outcome.summary.contains(
            "do not claim the source was mutated until it is"))
    }

    /// THE SHIPPED PACKAGE, not a fixture — and the real turn-signal bridge,
    /// not a hand-rolled stand-in. The two tests above pin the pure
    /// clause-generation mechanism against a minimal fixture skill; this one
    /// answers the question a fixture cannot: does the REAL `writing.mary`
    /// `writing.revise-selection` (which additionally declares
    /// `requirements.interactions: ["interaction.text-selection"]`, gated at
    /// dispatch by `AbilityRuntime.dispatchEligibilityFailure`) actually
    /// dispatch end to end for a genuine routed selection, through the exact
    /// bridge (`SchemaSignalRuntime.snapshotForTurn(ambientSelection:)`) the
    /// real turn loop uses (`MaryBrain+TurnLoop.swift`) to turn an
    /// `AmbientSelectionHandoff` into that Interaction. A live probe attempt
    /// against a real, running TextEdit selection (`mary-corpus-probe
    /// --dispatch-revise-selection`, written and then removed during this
    /// fix) hit exactly this gate from outside `MaryBrain` —
    /// `SchemaSignalTurnContext` is module-internal, so only a real
    /// conversational turn or a `@testable` test can satisfy it. This is
    /// that test.
    @Test func reviseSelectionDispatchesForRealAgainstTheShippedWritingPackage() async throws {
        guard let abilities = InstalledPackages.installed() else { return }
        // `writing`'s ability-level `operatingPolicy.defaultSupportingAbilities`
        // names `window-management`, so it has to load alongside `writing.mary`
        // for `SkillExecutionAvailabilityEvaluator`'s supporting-Ability check
        // to pass — the real app always loads the whole shipped set together.
        let names = ["writing", "window-management"]
        var records: [AbilityPackageRecord] = []
        for name in names {
            let candidate = abilities.appendingPathComponent("\(name).mary")
            guard FileManager.default.fileExists(atPath: candidate.path) else { return }
            records.append(AbilityPackageRecord(
                package: try AbilityPackageCodec.load(from: candidate),
                source: .sourceTree,
                sourceURL: candidate,
                validation: .init(),
                rawData: Data()))
        }
        // `writing.revise-selection` also requires the current Perception
        // `perception.workspace-focus` — in the shipped app this comes from
        // `route.leadPlace` naming a taught application's *registered*
        // workspace-class profile (`AmbientApplicationIndexProvider`, a
        // process-wide singleton this suite must not mutate — it is shared
        // with every other parallel test). Publishing the Perception
        // directly, through a scoped, non-shared `SchemaSignalRuntime()`
        // instance and a locally-fabricated adapter manifest — the exact
        // pattern `PlayerTransportPerceptionTests` established for
        // `perception.player-transport` — reaches the same requirement
        // honestly (a real, schema-validated Perception the real skill's own
        // declared schema accepts) without that global mutation.
        let workspaceFocusAdapterID = AdapterID("tests.workspace-focus")
        let workspaceFocusManifest = InstalledAdapterManifest(
            adapterID: workspaceFocusAdapterID,
            title: "Workspace Focus Test Adapter",
            transport: .native,
            providesPerceptions: [.workspaceFocus])
        let snapshot = AbilityRuntimeSnapshot(
            records: records,
            validation: .init(),
            adapterManifests: [workspaceFocusManifest])

        let now = Date()
        let ambient = AmbientContextStore()
        let attention = AmbientAttention(
            tier: .selection,
            world: .applications,
            applicationID: "com.apple.TextEdit",
            selectedText: "the quick brown fox",
            selectionEditability: .editable,
            selectionSourceEvidence: .exactElement,
            capturedAt: now)
        ambient.noteRoute(AmbientRoute(
            intent: .revise,
            decidedBy: .editIntent,
            attention: attention,
            selectionDefinesTurn: true,
            writingTarget: .selection))
        let handoff = AmbientSelectionHandoff(
            world: .applications,
            applicationID: "com.apple.TextEdit",
            processID: 4242,
            text: "the quick brown fox",
            editability: .editable,
            capturedAt: now,
            channel: .accessibilityNotification,
            sourceEvidence: .exactElement)
        ambient.recordSelection(handoff, at: now)

        // A FRESH, UNSHARED RUNTIME — never `.shared` — so this test can
        // publish into it without leaking a fact into any other suite.
        let signalRuntime = SchemaSignalRuntime()
        _ = try signalRuntime.publishPerception(
            schemaID: .workspaceFocus,
            value: ValueEnvelope(
                typeID: "writing.surface-focus",
                value: .object([
                    "application": .string("TextEdit"),
                    "editable": .boolean(true),
                ]),
                scope: SourceScope(applicationID: "com.apple.TextEdit"),
                provenance: .init(operation: "test"),
                privacy: .private,
                createdAt: now),
            adapterID: workspaceFocusAdapterID,
            registry: snapshot,
            now: now)

        // THE SAME BRIDGE `MaryBrain+TurnLoop.swift` calls before every real
        // turn — real, not simulated: it reads `writing.mary`'s own declared
        // `interaction.text-selection` InteractionSchema off `snapshot` and
        // validates the handoff against it exactly as production does.
        let signalSnapshot = signalRuntime.snapshotForTurn(
            registry: snapshot, ambientSelection: handoff, at: now)
        #expect(signalSnapshot.interactions.contains {
            $0.reference.schemaID == .textSelection
        }, "the real bridge turned the live selection into a genuine Interaction")
        #expect(signalSnapshot.perceptionIDs.contains(.workspaceFocus))

        let runtime = AbilityRuntime(
            plugins: [],
            standalone: [],
            executionLog: AbilityExecutionLog(),
            ambient: ambient,
            passages: PassageRegistry()) {
                AbilityExecutionContext(projects: [:])
            }

        let outcome = await AbilityTurnContext.$snapshot.withValue(snapshot) {
            await SchemaSignalTurnContext.$snapshot.withValue(signalSnapshot) {
                await runtime.dispatch(
                    name: "revise_selection",
                    argumentsJSON: #"{"instruction":"make it more upbeat"}"#)
            }
        }

        #expect(outcome.ok, "\(outcome.summary)")
        #expect(outcome.summary.contains(
            "call type_at_cursor with mode: \"replace_selection\""))
        #expect(outcome.summary.contains("in this same response"))
    }

    // MARK: - Fixture

    private func dispatchReviseSelection(ambient: AmbientContextStore) async -> SkillOutcome {
        let skill = SkillSchema(
            id: "writing.revise-selection",
            title: "Revise Selection",
            summary: "Revise the verified selection.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: "revise_selection"))
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.revise-selection-placement",
                version: "1.0.0",
                publisher: "tests",
                summary: "revise_selection placement-clause fixture."),
            ability: .init(
                id: .writing,
                title: "Writing",
                summary: "Writing fixture.",
                tint: "#112233",
                skills: [skill.id]),
            skills: [skill])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/revise-selection-placement.mary"),
            validation: .init(),
            rawData: Data())
        let snapshot = AbilityRuntimeSnapshot(
            records: [record],
            validation: .init(),
            adapterManifests: [])

        let runtime = AbilityRuntime(
            plugins: [],
            standalone: [],
            executionLog: AbilityExecutionLog(),
            ambient: ambient,
            passages: PassageRegistry()) {
                AbilityExecutionContext(projects: [:])
            }

        return await AbilityTurnContext.$snapshot.withValue(snapshot) {
            await runtime.dispatch(
                name: "revise_selection",
                argumentsJSON: #"{"instruction":"tighten this"}"#)
        }
    }
}
