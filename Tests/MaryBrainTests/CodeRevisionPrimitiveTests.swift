//
//  CodeRevisionPrimitiveTests.swift
//  MaryBrainTests
//
//  THE CODING HALF OF `[Corpus N]`'s SEAM. `.reviseSelection` is scoped to
//  `.writing` and gated on `interaction.text-selection` — an identity a
//  coding place's selection never mints — so "make this comment more
//  concise" on a real Xcode selection reached no revision procedure at all
//  and fell through to the zero-invocations reply. `.reviseCodeSelection` is
//  the same procedure under coding's own contract, gated on
//  `interaction.code-selection` (`[Corpus W]`).
//
//  Structured exactly like `CognitivePrimitivePlacementTests`: two fixture
//  tests pin the clause mechanism's branches, and one dispatches the REAL
//  shipped `coding.mary` `coding.revise-selection` end to end through the
//  REAL `SchemaSignalRuntime` bridge.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryPlugin

@Suite struct CodeRevisionPrimitiveTests {

    // MARK: - The contract

    /// THE EXACT-MATCH LOOKUP IS THE SECURITY BOUNDARY, so the contract has
    /// to answer for the coding identity and refuse every neighbouring one:
    /// a package cannot reach a reasoning procedure by borrowing half of
    /// another Ability's name.
    @Test func theCodeRevisionContractIsScopedToCodingsOwnSkillIdentity() {
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .coding,
                skillID: "coding.revise-selection",
                invocationName: "revise_code_selection"))?.primitive
            == .reviseCodeSelection)

        // Same Skill id, wrong Ability.
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .writing,
                skillID: "coding.revise-selection",
                invocationName: "revise_code_selection")) == nil)
        // Right Ability, writing's invocation name.
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .coding,
                skillID: "coding.revise-selection",
                invocationName: "revise_selection")) == nil)
        // Writing's own primitive is untouched by any of this.
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .writing,
                skillID: "writing.revise-selection",
                invocationName: "revise_selection"))?.primitive
            == .reviseSelection)
    }

    // MARK: - The placement clause

    @Test func codeRevisionAppendsThePlacementClauseWhenACodingSelectionIsRouted() async {
        let now = Date()
        let ambient = AmbientContextStore()
        Self.route(ambient, application: taughtCodingID,
                   bundleID: taughtCodingBundleID, at: now)

        let outcome = await withTaughtRoster { () async -> SkillOutcome in
            // The predicate the clause gates on, proven against the fixture
            // rather than assumed: a routed selection whose PLACE codes.
            #expect(ambient.routedSelectionHandoff()?.place.focus == .coding)
            return await Self.dispatchReviseCodeSelection(ambient: ambient)
        }

        #expect(outcome.ok, "\(outcome.summary)")
        #expect(outcome.summary.contains("call replace_selection with the revised code"))
        #expect(outcome.summary.contains("in this same response"))
        #expect(outcome.summary.contains(
            "never claim the file changed until that call returns ok"))
        // THE CORPUS IS NAMED, NOT ATTACHED — the activation instructs the
        // reads that reach surrounding context, because nothing wires them.
        #expect(outcome.summary.contains("read_selection"))
        #expect(outcome.summary.contains("search_corpus"))
    }

    @Test func codeRevisionOmitsThePlacementClauseWithNoRoutedSelection() async {
        let ambient = AmbientContextStore()
        #expect(ambient.routedSelectionHandoff() == nil)

        let outcome = await Self.dispatchReviseCodeSelection(ambient: ambient)

        #expect(outcome.ok)
        #expect(!outcome.summary.contains("replace_selection"))
        #expect(outcome.summary.contains("Do not claim the file changed until it has"))
    }

    /// A PROSE SELECTION IS NOT A CODE SELECTION, and the clause must not
    /// fire for one even though the primitive was somehow reached. This is
    /// the writing lane's guard rail from the other side.
    @Test func codeRevisionOmitsThePlacementClauseForAProseSelection() async {
        let now = Date()
        let ambient = AmbientContextStore()
        Self.route(ambient, application: taughtWritingID,
                   bundleID: taughtWritingBundleID, at: now)

        let outcome = await withTaughtRoster { () async -> SkillOutcome in
            #expect(ambient.routedSelectionHandoff()?.place.focus == .writing)
            return await Self.dispatchReviseCodeSelection(ambient: ambient)
        }

        #expect(outcome.ok)
        #expect(!outcome.summary.contains("replace_selection"))
    }

    // MARK: - The shipped package, end to end

    /// THE REAL `coding.mary`, THE REAL BRIDGE. The fixture tests above pin
    /// clause generation; this answers what a fixture cannot — that the
    /// shipped `coding.revise-selection`, which additionally declares
    /// `requirements.interactions: ["interaction.code-selection"]` and is
    /// gated at dispatch by `AbilityRuntime.dispatchEligibilityFailure`,
    /// actually dispatches for a genuine coding selection through the exact
    /// bridge (`SchemaSignalRuntime.snapshotForTurn(ambientSelection:)`) the
    /// real turn loop uses. Before `[Corpus W]` this could not have passed
    /// at any layer: the Interaction had no schema to mint against.
    @Test func codeRevisionDispatchesForRealAgainstTheShippedCodingPackage() async throws {
        guard let abilities = InstalledPackages.installed() else { return }
        var records: [AbilityPackageRecord] = []
        // `coding`'s own `operatingPolicy.defaultSupportingAbilities` names
        // `window-management`, so it must load alongside for
        // `SkillExecutionAvailabilityEvaluator`'s supporting-Ability check.
        for name in ["coding", "window-management"] {
            let candidate = abilities.appendingPathComponent("\(name).mary")
            guard FileManager.default.fileExists(atPath: candidate.path) else { return }
            records.append(AbilityPackageRecord(
                package: try AbilityPackageCodec.load(from: candidate),
                source: .sourceTree,
                sourceURL: candidate,
                validation: .init(),
                rawData: Data()))
        }
        let snapshot = AbilityRuntimeSnapshot(
            records: records, validation: .init(), adapterManifests: [])

        let now = Date()
        let ambient = AmbientContextStore()
        let handoff = Self.route(
            ambient, application: taughtCodingID,
            bundleID: taughtCodingBundleID, at: now)
        ambient.noteUtterance("make this comment more concise")

        let outcome = await withTaughtRoster { () async -> SkillOutcome in
            // A FRESH, UNSHARED RUNTIME — never `.shared`.
            let signalSnapshot = SchemaSignalRuntime().snapshotForTurn(
                registry: snapshot, ambientSelection: handoff, at: now)
            #expect(signalSnapshot.interactionIDs.contains(.codeSelection),
                    "the real bridge minted the Interaction the Skill requires")

            let runtime = AbilityRuntime(
                plugins: [],
                standalone: [],
                executionLog: AbilityExecutionLog(),
                ambient: ambient,
                passages: PassageRegistry()) {
                    AbilityExecutionContext(projects: [:])
                }
            return await AbilityTurnContext.$snapshot.withValue(snapshot) {
                await SchemaSignalTurnContext.$snapshot.withValue(signalSnapshot) {
                    await runtime.dispatch(
                        name: "revise_code_selection",
                        argumentsJSON: #"{"instruction":"make it more concise"}"#)
                }
            }
        }

        #expect(outcome.ok, "\(outcome.summary)")
        #expect(outcome.summary.contains("Code revision procedure activated"))
        #expect(outcome.summary.contains("call replace_selection with the revised code"))
    }

    // MARK: - Fixture

    @discardableResult
    private static func route(
        _ ambient: AmbientContextStore,
        application: String,
        bundleID: String,
        at now: Date
    ) -> AmbientSelectionHandoff {
        let text = "// tally the results before we hand them back"
        // `AmbientRoute.admitsSelectionHandoff` compares the attention's
        // `applicationID` to the handoff's, so the attention carries the
        // BUNDLE id; the handoff additionally carries the logical id, which
        // is what `place` (and therefore `focus`) is spelled with.
        let attention = AmbientAttention(
            tier: .selection,
            world: .applications,
            applicationID: bundleID,
            selectedText: text,
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
            application: application,
            applicationID: bundleID,
            processID: 4242,
            text: text,
            editability: .editable,
            capturedAt: now,
            channel: .accessibilityNotification,
            sourceEvidence: .exactElement)
        ambient.recordSelection(handoff, at: now)
        return handoff
    }

    private static func runtimeSkill(
        ability: AbilityID,
        skillID: SkillID,
        invocationName: String
    ) -> AbilityRuntimeSkill {
        let skill = SkillSchema(
            id: skillID,
            title: "Revise",
            summary: "Revise the verified selection.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: invocationName))
        return Self.record(ability: ability, skill: skill).0
    }

    private static func record(
        ability: AbilityID,
        skill: SkillSchema
    ) -> (AbilityRuntimeSkill, AbilityRuntimeSnapshot) {
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.code-revision",
                version: "1.0.0",
                publisher: "tests",
                summary: "revise_code_selection fixture."),
            ability: .init(
                id: ability,
                title: "Fixture",
                summary: "Fixture ability.",
                tint: "#112233",
                skills: [skill.id]),
            skills: [skill])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/code-revision.mary"),
            validation: .init(),
            rawData: Data())
        let snapshot = AbilityRuntimeSnapshot(
            records: [record], validation: .init(), adapterManifests: [])
        let runtime = snapshot.skills.first { $0.skill.id == skill.id }!
        return (runtime, snapshot)
    }

    private static func dispatchReviseCodeSelection(
        ambient: AmbientContextStore
    ) async -> SkillOutcome {
        let skill = SkillSchema(
            id: "coding.revise-selection",
            title: "Revise the Selected Code",
            summary: "Revise the verified code selection.",
            kind: .cognitive,
            execution: .init(kind: .cognitive),
            modelExposure: .init(invocationName: "revise_code_selection"))
        let (_, snapshot) = Self.record(ability: .coding, skill: skill)
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
                name: "revise_code_selection",
                argumentsJSON: #"{"instruction":"tighten this"}"#)
        }
    }
}
