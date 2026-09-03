//
//  WritingReachabilityTests.swift
//  MaryBrainTests
//
//  WHAT: Shipped writing.mary is reachable from a manuscript workspace.
//  OUT:  PluginCompiler profile join + AmbientEngine + AbilityRoutingEvaluator
//  PIN:  Realization joins the discipline; a coding workspace does not admit writing
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation

@Suite struct WritingReachabilityTests {

    // MARK: - 0. The real installed Scrivener has to be RECOGNIZED at all

    /// THE LIVE-ONLY BUG THIS PINS: `mary-corpus-probe project --dispatch`
    /// against a real Scrivener 3 with a real manuscript open found
    /// `search_corpus`/`read_corpus_outline`/`read_corpus_document`/
    /// `corpus_progress` unreachable through real `AbilityRuntime.dispatch` —
    /// every one of them missing from the turn's own projected roster —
    /// even though every unit test and `mary-package-probe check` passed and
    /// `mary-corpus-probe project --live` read the manuscript fine.
    ///
    /// THE CAUSE was a split between two independent "does this bundle id
    /// belong to us" implementations. `ProjectCorpusSupport.openCorpora()`
    /// (which found the project) asks `CorpusRegistration.owns(bundleID:)`,
    /// a raw `hasPrefix` over `bundleIdentifiers` — lenient enough that it
    /// matched `com.literatureandlatte.scrivener3` (the real installed
    /// Scrivener 3) against the declared `com.literatureandlatte.scrivener`
    /// on its own. Ambient routing asks a DIFFERENT type,
    /// `ApplicationRegistration.owns(bundleID:)`, which requires an exact
    /// match unless the package separately declares `bundleIdentifierPrefix`
    /// — and `scrivener.mary` never did. So `WorkspaceFocusTracker` could
    /// never recognize the real Scrivener 3 as the taught `scrivener`
    /// application; it fell to the generic "some app I don't know" terminal
    /// arm, the lead carried no `writing` discipline, and every Skill this
    /// file's other tests prove reachable from a writing workspace was
    /// silently never reachable from the one manuscript application shipped
    /// to actually be a writing workspace. Fixed by declaring
    /// `plugin.application.bundleIdentifierPrefix` on `scrivener.mary`
    /// (2026-08-28); this test is the fast, no-GUI pin so it cannot come
    /// back silently.
    @Test func theRealScrivener3BundleIDIsRecognizedAsTheScrivenerApplication() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("scrivener"), try loadRootPackage("writing")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let profile = try #require(
            compilation.applicationProfiles.first { $0.id == "scrivener" })
        // THE FIELD ITSELF, not just its effect: a future edit that removes
        // the prefix should fail exactly here, one line from the cause.
        #expect(
            profile.applicationBundlePrefix == "com.literatureandlatte.scrivener",
            "the package must declare the family, not just the exact identity")

        // THE EFFECT `WorkspaceFocusTracker`/`AmbientApplicationIndexProvider`
        // actually depend on — the same `registration(for:)` join
        // `AmbientApplicationBridge.install` performs in the shipped app.
        let registration = AmbientApplicationBridge.registration(for: profile)
        #expect(registration.owns(bundleID: "com.literatureandlatte.scrivener3"),
                "the real, versioned Scrivener 3 bundle id must resolve to this registration")
        #expect(registration.owns(bundleID: "com.literatureandlatte.scrivener"),
                "the exact declared id still resolves too")
        #expect(!registration.owns(bundleID: "com.example.scrivener"),
                "a different vendor's app merely containing the name must not")
    }

    // MARK: - 1. The profile carries the discipline that claims the app

    /// AN APPLICATION JOINS A DISCIPLINE BY REALIZING ONE OF ITS SKILLS —
    /// which is proof rather than a list.
    ///
    /// A discipline package CAN name applications outright
    /// (`ability.applications`), and Mary's own do not. The list is the wrong
    /// channel: it makes the discipline's author decide which applications
    /// count, so the three they thought of are writing applications and every
    /// editor installed afterwards is not — no matter what its own package
    /// says about itself. Realization inverts that. The application declares
    /// what it can do, the discipline finds out, and nobody has to be
    /// enumerated in advance.
    @Test func anApplicationJoinsTheDisciplineItRealizesASkillFor() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("textedit"), try loadRootPackage("writing")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "textedit" })
        #expect(editor.abilities.contains(AbilityID("textedit")), "its own ability")
        #expect(
            editor.abilities.contains(.writing),
            "it realizes writing.save-document, so it is a writing application")
    }

    /// AND ONLY THAT DISCIPLINE. Merely being installed alongside one does
    /// not join it — otherwise every profile would carry every discipline and
    /// the register test would mean nothing.
    @Test func anUnrealizedDisciplineDoesNotJoinTheProfile() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [
                try loadRootPackage("textedit"),
                try loadRootPackage("writing"),
                try loadRootPackage("window-management"),
            ],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "textedit" })
        #expect(editor.abilities.contains(.writing), "it realizes a writing skill")
        #expect(
            !editor.abilities.contains(AbilityID("window-management")),
            "it realizes none of window-management's, so it does not join it")
    }

    // MARK: - 2. A manuscript turn is a writing turn

    /// With the profile fixed, an action turn led by Scrivener reads as
    /// `compose` — the register the whole Writing vocabulary hangs off.
    @Test func anActionTurnLedByAManuscriptIsAWritingTurn() {
        let scrivener = ApplicationProfile(
            id: "scrivener",
            title: "Scrivener",
            summary: "Manuscript.",
            abilities: [AbilityID("scrivener"), .writing],
            aliases: ["scrivener", "manuscript"])
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: "write a paragraph about the Queen of Vanta",
            actionTurn: true,
            leadApplicationID: "scrivener",
            profiles: [scrivener]))

        #expect(route.intent == AmbientIntent.compose)
        #expect(route.decidedBy == AmbientSignal.writingRegister)
    }

    /// And the same turn WITHOUT the discipline on the profile is the bug:
    /// kept as the negative half so the mechanism is visible rather than
    /// implied.
    @Test func theSameTurnWithoutTheDisciplineFallsToOperate() {
        let scrivener = ApplicationProfile(
            id: "scrivener",
            title: "Scrivener",
            summary: "Manuscript.",
            abilities: [AbilityID("scrivener")],
            aliases: ["scrivener", "manuscript"])
        let route = AmbientEngine.resolve(AmbientEngine.Inputs(
            utterance: "write a paragraph about the Queen of Vanta",
            actionTurn: true,
            leadApplicationID: "scrivener",
            profiles: [scrivener]))

        #expect(route.intent == AmbientIntent.operate)
    }

    // MARK: - 3. Being in a writing world is enough to reach Writing

    /// THE OFFER GATE TURNS ON A PHYSICAL FACT NOW.
    ///
    /// The three original predicates are all classifier output, so a turn the
    /// classifier read as anything else — a bare "yes please do" answering a
    /// proposal, which resolves to `.decide` — dropped the entire Writing
    /// Ability out of the roster and took `type_at_cursor` with it. Sitting in
    /// a manuscript is not a reading of the sentence; it is where the user is.
    /// THIS TEST HAND-BUILT A VALUE NO TAUGHT TURN COULD PRODUCE, and for a
    /// while that made it a promise rather than a proof: `workspaceFamily` was
    /// `route.lead?.ability`, and `AmbientAttention.ability` answers only for the
    /// compiled worlds — so the guarantee "being in a writing workspace is
    /// enough" held in Pages and nowhere else. It is real now because the value
    /// comes off `route.leadPlace`, which a taught application resolves through
    /// its registration — see `TurnWorldExtractionTests`.
    @Test func theWritingAbilityIsReachableFromAWritingWorkspaceAlone() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing").ability
        let inAManuscriptAnsweringYes = AbilityRoutingContext(
            utterance: "yes please do",
            intent: AmbientIntent.decide.rawValue,
            workspaceFamily: AbilityID.writing.rawValue)

        #expect(
            AbilityRoutingEvaluator.isEligible(writing.routing, in: inAManuscriptAnsweringYes),
            "the typer must survive a turn the classifier did not read as compose")
    }

    /// The predicate is not a blank cheque: a coding workspace with none of the
    /// writing signals still does not admit the Writing Ability.
    @Test func aCodingWorkspaceStillDoesNotAdmitWriting() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing").ability
        let inXcode = AbilityRoutingContext(
            utterance: "run the tests",
            intent: AmbientIntent.operate.rawValue,
            workspaceFamily: "coding")

        #expect(!AbilityRoutingEvaluator.isEligible(writing.routing, in: inXcode))
    }

    // MARK: - 4. A coding workspace's OWN project corpus is the one exception

    /// LIVE-ONLY BUG, found by `mary-corpus-probe project --dispatch-code`
    /// against a real Xcode with this checkout open: `xcode.mary` declaring
    /// `corpus.structure` (fileSystemTree) gave Xcode `search_corpus` /
    /// `read_corpus_outline` / `read_corpus_document` / `corpus_progress`
    /// structurally — `mary-package-probe check` was green — and every one
    /// of them was still missing from the turn's own projected roster,
    /// because those four Skills are declared inside `writing.mary` and
    /// gated by ITS Ability-level routing policy, which
    /// `aCodingWorkspaceStillDoesNotAdmitWriting` above pins as NOT admitting
    /// a bare coding workspace. Unlike Scrivener (admitted by
    /// `workspaceFamily=="writing"` alone, regardless of the utterance), an
    /// ordinary coding question — "find where the code mentions X" — reads
    /// as neither `compose`/`revise` nor a text-selection interaction, so
    /// none of the other three arms fired either.
    ///
    /// THE FIX IS A FIFTH ARM, doubly-qualified rather than widened: `all(
    /// workspaceFamily=="coding", targetClass=="writing-project")`. A bare
    /// coding workspace never carries `writing-project` — only one that ALSO
    /// declares a `corpus.structure` does, because that target class is what
    /// `AbilityRuntime.abilityRoutingContext()` unions in from the LEAD
    /// application's own `plugin.application.targetClasses`
    /// (`xcode.mary` added it alongside `code-workspace`/`document-window`
    /// for exactly this). So this admits Writing for a project-reading
    /// question in Xcode without reopening `aCodingWorkspaceStillDoesNotAdmitWriting`'s
    /// door — that fixture carries no target classes at all, so the new arm
    /// stays shut for it, which is the pin below.
    @Test func aCodingWorkspaceWithItsOwnCorpusAdmitsWritingForTheCorpusLane() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing").ability
        let inXcodeWithACorpus = AbilityRoutingContext(
            utterance: "find where the code mentions PluginCorpusStructureSchema",
            intent: AmbientIntent.operate.rawValue,
            targetClasses: ["writing-project"],
            workspaceFamily: "coding")

        #expect(AbilityRoutingEvaluator.isEligible(writing.routing, in: inXcodeWithACorpus))
    }

    /// THE NARROWNESS, pinned separately from the positive: a coding
    /// workspace that does NOT declare `writing-project` — the ordinary case
    /// `aCodingWorkspaceStillDoesNotAdmitWriting` already covers — must stay
    /// shut even with the new arm in place. Restated here with an EXPLICIT
    /// `targetClasses: []` so a future edit that widens the new arm's second
    /// child fails exactly on this line rather than on the older test above.
    @Test func aCodingWorkspaceWithNoCorpusStillDoesNotAdmitWriting() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing").ability
        let inXcodeWithNoCorpus = AbilityRoutingContext(
            utterance: "run the tests",
            intent: AmbientIntent.operate.rawValue,
            targetClasses: [],
            workspaceFamily: "coding")

        #expect(!AbilityRoutingEvaluator.isEligible(writing.routing, in: inXcodeWithNoCorpus))
    }

    /// Exact-match lookup is the security boundary: writing's revision
    /// primitive cannot be reached by borrowing another Ability's identity.
    @Test func reviseSelectionIsWritingsRevisionPrimitive() {
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .writing,
                skillID: "writing.revise-selection",
                invocationName: "revise_selection"))?.primitive
            == .reviseSelection)
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .coding,
                skillID: "writing.revise-selection",
                invocationName: "revise_selection")) == nil)
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
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.writing-revision",
                version: "1.0.0",
                publisher: "tests",
                summary: "revise_selection identity fixture."),
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
            sourceURL: URL(fileURLWithPath: "/tmp/writing-revision.mary"),
            validation: .init(),
            rawData: Data())
        let snapshot = AbilityRuntime.Snapshot(
            records: [record], validation: .init(), adapterManifests: [])
        return snapshot.skills.first { $0.skill.id == skill.id }!
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
