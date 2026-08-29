//
//  CodingDisciplineTests.swift
//  MaryBrainTests
//
//  THE CODING DISCIPLINE, AS SHIPPED — the road `coding.mary` and
//  `xcode.mary` have to travel before Mary can be asked to build anything.
//
//  WHAT MAKES THIS WORTH ITS OWN SUITE. `WritingReachabilityTests` pins the
//  same road for writing, and it exists because three separate defects had to
//  line up before a manuscript could be typed into. Coding is the second
//  discipline to travel that road, and for its build/run/test/save/stop
//  Skills alone it is still the one with no compiled provider anywhere
//  behind it — writing has the prose-surface adapter, coding has only
//  declarations there. `read_buffer`/`read_selection` broke that (the
//  code-surface adapter), and the road they travel is exactly this suite's
//  own — including a real ability-conflict regression the live probe found
//  and this file now pins (see `codingStaysActiveAlongsideWritingWhenXcode
//  HasAProjectCorpus`). Every rung here is therefore load-bearing in a way
//  the writing equivalents are not, because nothing else would catch a
//  break.
//
//  AND ONE RUNG IS NEWLY REPAIRED. `AmbientPlace.ability` used to break ties
//  with `AmbientWorld.realizedAbilities`, which the world shrink left
//  permanently empty — so a taught application's craft came back as whichever
//  of its ability ids sorted first alphabetically. For an editor that is its
//  OWN id ("xcode" before "coding"), which would leave `focus` nil and the
//  `workspaceFamily == "coding"` predicate unreachable. The order now comes
//  from `WorkspaceFocus`. These tests are what stop that from rotting back.
//

import Foundation
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct CodingDisciplineTests {

    // MARK: - The discipline is joined by realizing, not by being listed

    /// THE EDITOR JOINS CODING BECAUSE IT REALIZES CODING'S SKILLS.
    ///
    /// `coding.mary` names no applications — deliberately, the same call
    /// `writing.mary` makes. If this fails, either the realization block lost
    /// its `skillID`s or the compiler stopped reading realization owners, and
    /// every rung below it is meaningless.
    @Test func theEditorJoinsCodingByRealizingItsSkills() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("xcode"), try loadRootPackage("coding")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        #expect(editor.abilities.contains(AbilityID("xcode")), "its own ability")
        #expect(
            editor.abilities.contains(.coding),
            "it realizes coding's build/run/test skills, so it is a coding application")
    }

    /// AND NOT WRITING. A code editor must never read as a prose workspace:
    /// that is the distinction the whole rival-writing bar rests on, and the
    /// one `SelectionSurfacePolicy` enforces from the other direction.
    @Test func theEditorIsNotAWritingApplication() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [
                try loadRootPackage("xcode"),
                try loadRootPackage("coding"),
                try loadRootPackage("writing"),
            ],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })

        let editor = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        #expect(editor.abilities.contains(.coding))
        #expect(
            !editor.abilities.contains(.writing),
            "it realizes none of writing's skills, so it does not join writing")
    }

    // MARK: - The compiled profile projects onto the discipline axis

    /// THE JOIN THE TIE-BREAK REPAIR EXISTS FOR.
    ///
    /// `abilities` is a `Set` holding BOTH "xcode" and "coding", and the place
    /// has to project that onto `WorkspaceFocus`. Under the old alphabetical
    /// fallback "xcode" lost to nothing and won the tie, `focus` came back
    /// nil, and a code workspace silently had no discipline at all.
    @Test func theEditorsPlaceReadsAsCoding() throws {
        guard InstalledPackages.installed() != nil else { return }
        let compilation = PluginCompiler.compile(
            packages: [try loadRootPackage("xcode"), try loadRootPackage("coding")],
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        let profile = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        // THE COMPILED PERCEPTION, not a hand-picked stand-in — this used to
        // be `ApplicationPerception(kind: .workspace, documentOperation: nil,
        // pollSeconds: 3)`, written when both surfaces were nil for xcode and
        // so happened to agree with `profile.perception` by coincidence.
        // Threading the real compiled value through is what lets this test
        // actually track `PluginCompiler.perception(from:proseSurface:
        // codeSurface:)`'s behaviour rather than a fixed copy of it.
        let perception = try #require(profile.perception)

        try AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "xcode",
                    profile: profile,
                    bundleIdentifiers: ["com.apple.dt.Xcode"],
                    worldClass: .workspace,
                    displayName: "Xcode",
                    perception: perception),
            ])
        ) {
            let place = AmbientPlace.application("xcode")
            #expect(place.focus == .coding, "the discipline it realized")
            // EYES, NOW THAT THE CODE-SURFACE ADAPTER HAS LANDED. `hasEyes`
            // requires a channel that reads the application's documents, and
            // `xcode.mary` now declares `codeSurface` — the read-only live
            // buffer/selection channel `PluginCompiler.perception(from:
            // proseSurface:codeSurface:)` folds in alongside a prose surface
            // for exactly this. This is the flip the comment here used to
            // promise; see the fixed test's history for the "no eyes" state
            // it replaced.
            #expect(place.hasEyes, "the code-surface adapter gives it eyes")
            // THE SAME VALUE THE ROSTER GATE READS. `workspaceFamily` is
            // `leadPlace.ability?.rawValue`, and `coding.mary` admits itself
            // through a `workspaceFamily == "coding"` predicate — the one
            // admission road that does not depend on classifying a sentence.
            #expect(place.ability == .coding)
        }
    }

    // MARK: - What the packages promise

    /// EVERY CHORD-SHAPED CODING SKILL IS REALIZED BY THE EDITOR. A
    /// discipline skill left with `.pluginRealizations` and no realization
    /// anywhere is installed-but-blocked, which the validator reports as a
    /// note and a user experiences as Mary agreeing to do something and then
    /// not doing it.
    ///
    /// ONLY `.pluginRealizations` SKILLS ARE CHECKED HERE — build, run, test,
    /// stop, save-all, the ones with no compiled provider behind them, which
    /// is this suite's own header claim ("coding … has nothing but
    /// declarations"). `read_buffer`/`read_selection` broke that claim on
    /// purpose: they carry `.authoredBindings` straight to the code-surface
    /// adapter, `writing.read-corpus-outline`'s exact shape for the
    /// project-corpus adapter, and need no per-editor realization at all —
    /// any application that declares a `codeSurface` answers them the same
    /// way, without `xcode.mary` naming them.
    @Test func everyCodingSkillHasARealization() throws {
        guard InstalledPackages.installed() != nil else { return }
        let coding = try loadRootPackage("coding")
        let editor = try loadRootPackage("xcode")

        let declared = Set(
            coding.skills
                .filter { $0.execution.realizationPolicy == .pluginRealizations }
                .map(\.id.rawValue))
        let realized = Set(
            (editor.plugin?.realizations ?? []).map(\.skillID.rawValue))
        #expect(declared == realized, """
            Every plugin-realized Skill the coding discipline declares must be \
            realized by the editor package, and the editor must realize nothing \
            the discipline does not declare.
            declared only: \(declared.subtracting(realized).sorted())
            realized only: \(realized.subtracting(declared).sorted())
            """)
    }

    /// EVERY OPERATION IS A CHORD THE HANDS CAN POST.
    ///
    /// `MaryHands` posts key chords, text, waits and window rebinds; the
    /// compiler refuses a pointer step before the stage is ever taken. A
    /// shipped package containing one would validate, install, and fail at
    /// first use — so the check belongs on the packages, not on the executor.
    @Test func everyEditorOperationIsPerformable() throws {
        guard InstalledPackages.installed() != nil else { return }
        let editor = try loadRootPackage("xcode")
        let performable: Set<PluginRecipeStepKind> =
            [.keyChord, .typeText, .wait, .rebindFocusedWindow]

        for operation in editor.plugin?.operations ?? [] {
            for step in operation.steps {
                #expect(
                    performable.contains(step.kind),
                    "\(operation.operation) step \(step.id) is \(step.kind), which Mary's hands cannot post")
            }
        }
    }

    // MARK: - The ability-conflict regression: coding must not lose to writing

    /// LIVE-ONLY BUG, found by `mary-corpus-probe --dispatch-code-surface`
    /// against a real Xcode with this checkout open: `read_buffer`/
    /// `read_selection` were absent from the turn's own projected roster —
    /// and so, it turned out, was `build_project`, for the SAME reason and on
    /// EVERY Xcode-led turn, not merely a code-surface one.
    ///
    /// THE MECHANISM. `xcode.mary` earned a `writing-project` target class
    /// when the corpus lane landed (Corpus G), and `writing.mary`'s own
    /// carve-out arm for it — `all(workspaceFamily=="coding",
    /// targetClass=="writing-project")` — is an `.all` predicate, which SUMS
    /// its children's scores: 100 (`workspaceFamily`) + 70 (`targetClass`) =
    /// 170. `coding.mary`'s own eligibility never exceeded 100 (its bare
    /// `workspaceFamily` arm, the highest of its `any` children). Both
    /// Abilities share `routing.conflictGroup: "ability"`, so any turn where
    /// BOTH read eligible enters a winner-take-all election
    /// (`AbilityRosterArbitrator.arbitrate`) — and Coding's 100 always lost
    /// to Writing's 170, for every utterance, because `targetClasses` comes
    /// from the LEAD APPLICATION'S profile unconditionally, not from
    /// anything the user said. Losing took Coding's ENTIRE discipline with
    /// it: not just two new Skills, but `build_project`/`run_project`/
    /// `test_project`/`stop_execution`/`save_all` too.
    ///
    /// WHY NO EXISTING TEST CAUGHT IT. `WritingReachabilityTests`'s own pins
    /// (`aCodingWorkspaceWithItsOwnCorpusAdmitsWritingForTheCorpusLane` etc.)
    /// check `AbilityRoutingEvaluator.isEligible` in ISOLATION — true for
    /// Writing, and correctly so — never the ability-vs-ability arbitration
    /// that eligibility feeds once a second Ability is also eligible. Only a
    /// turn with BOTH packages loaded and BOTH eligible exercises the
    /// conflict group at all.
    ///
    /// THE FIX adds the IDENTICAL arm to `coding.mary`'s own eligibility, so
    /// the two Abilities TIE (170 apiece) instead of Coding losing outright.
    /// `AbilityRosterArbitrator.arbitrate` already has a rule for a tie:
    /// every Ability whose rank vector equals the best one stays active — the
    /// same rule that already lets `design`/`sketch` and `browsing`/`chrome`
    /// coexist (see that function's own comment, "an accident that the next
    /// package to gate on `.intent` would have broken too" — this is that
    /// next package). This test drives the real package graph and the real
    /// arbitrator rather than the isolated predicate, which is exactly the
    /// layer `WritingReachabilityTests` could not reach.
    @Test func codingStaysActiveAlongsideWritingWhenXcodeHasAProjectCorpus() async throws {
        guard InstalledPackages.installed() != nil else { return }
        let xcode = try loadRootPackage("xcode")
        let coding = try loadRootPackage("coding")
        let writing = try loadRootPackage("writing")
        // BOTH DISCIPLINES DECLARE `window-management` A DEFAULT SUPPORTING
        // ABILITY — omitted, every one of their Skills (not just the ones
        // under test) reads `.blocked` with "requires supporting Ability
        // window-management", which is a fact about this fixture's package
        // set rather than about the routing this test exists to pin.
        let windowManagement = try loadRootPackage("window-management")
        let allPackages = [xcode, coding, writing, windowManagement]

        let compilation = PluginCompiler.compile(
            packages: allPackages,
            nativeAdapterManifests: [],
            grantedPermissions: { _ in [.accessibility] })
        let xcodeProfile = try #require(
            compilation.applicationProfiles.first { $0.id == "xcode" })
        let perception = try #require(xcodeProfile.perception)

        let validation = AbilityPackageValidator.validateGraph(allPackages)
        #expect(validation.isValid, "the shipped packages must load cleanly together")
        func record(_ package: MaryAbilityPackage) -> AbilityPackageRecord {
            AbilityPackageRecord(
                package: package, source: .installed,
                sourceURL: URL(fileURLWithPath: "/dev/null"),
                validation: validation,
                rawData: (try? AbilityPackageCodec.encoded(package)) ?? Data())
        }
        let snapshot = AbilityRuntimeSnapshot(
            records: allPackages.map(record),
            validation: validation,
            adapterManifests: MaryAdapterCatalog.adapterManifests(
                adapters: MaryAdapterCatalog.adapters(),
                // WITHOUT OBSERVERS, no manifest publishes
                // `perception.code-workspace-focus` (or its base,
                // `perception.workspace-focus`, via `DerivedPerceptions`) —
                // `InstalledAdapterInventory`'s own comment names this exact
                // mistake: "installed every Skill requiring
                // code-workspace-focus as `.blocked` — the whole coding lane,
                // in silence."
                observers: MaryAdapterCatalog.observers()),
            // WITHOUT THIS, `coding.build-project` (bound only through
            // `xcode.mary`'s plugin realization, not an authored binding)
            // has no local implementation at all in the snapshot and reads
            // `.blocked` before routing is ever consulted — a snapshot built
            // from `records` alone is NOT what `AbilityLibrary.configureAndLoad`
            // produces; the realized Plugin bindings are a second input,
            // joined in right here, and `compilation` (built above from the
            // SAME packages) is that second input.
            plugins: compilation)

        // A FRESH, ISOLATED STORE — never `.shared` — so this test cannot
        // race a concurrently running suite over the same global route.
        let ambient = AmbientContextStore()

        try await AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "xcode", profile: xcodeProfile,
                    bundleIdentifiers: ["com.apple.dt.Xcode"],
                    worldClass: .workspace, displayName: "Xcode",
                    perception: perception),
            ])
        ) {
            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "what does this function do",
                leadApplicationID: "xcode",
                profiles: [xcodeProfile]))
            #expect(route.leadPlace?.ability?.rawValue == "coding",
                    "the turn must actually read as a coding workspace for this to be a real test")
            ambient.noteUtterance("what does this function do")
            ambient.noteRoute(route)

            try await AbilityTurnContext.$snapshot.withValue(snapshot) {
                let runtime = AbilityRuntime(
                    plugins: MaryAdapterCatalog.adapters(),
                    ambient: ambient,
                    contextProvider: { AbilityExecutionContext(projects: [:]) })
                let offered = Set(runtime.schemas.map(\.name))
                #expect(offered.contains("build_project"),
                        "coding's own chord Skills must survive the ability conflict")
                #expect(offered.contains("search_corpus"),
                        "writing's corpus Skills must still be admitted too — a tie, not a loss")
                #expect(offered.contains("read_buffer"))
                #expect(offered.contains("read_selection"))
            }
        }
    }

    // MARK: - The read-only Skills must not hard-gate on a momentary perception

    /// PINS THE FIX FOR "why does Mary keep mutable rabbit": `coding.mary`
    /// used to declare `perceptions: ["perception.code-workspace-focus"]` as
    /// a HARD requirement on `read_buffer`/`read_selection` — the two
    /// read-only, `.native`-bound Skills in this package. `AbilityRuntime
    /// .isEligible`'s `hasPerception` predicate hard-excludes a Skill from
    /// the model-visible roster the instant a required perception is
    /// momentarily absent, so an ambiguous, non-imperative turn ("let's take
    /// a look at the code I have written here") could refuse both Skills
    /// even with Xcode genuinely frontmost.
    ///
    /// `writing.read-corpus-document`/`writing.search-corpus` already solved
    /// this exact class of bug: `perceptions: []` with the same perception
    /// moved to `optionalPerceptions`, which only steers routing preference
    /// and never hard-blocks. This test pins `coding.read-selection`/
    /// `coding.read-buffer` onto that identical shape, so a future author
    /// re-tightening either declaration back to a hard requirement fails
    /// here instead of silently reintroducing the refusal.
    ///
    /// `coding.build-project`/`run-project`/`test-project`/`save-all`/
    /// `stop-execution` are deliberately NOT covered — they are mutating
    /// managed-UI chords, a separate, still-open case per the plan this test
    /// accompanies, and this test would fail if their requirement were
    /// loosened by mistake alongside the two read-only Skills.
    @Test func readOnlyCodeSurfaceSkillsDoNotHardGateOnWorkspaceFocus() throws {
        guard InstalledPackages.installed() != nil else { return }
        let coding = try loadRootPackage("coding")

        let readOnlySkillIDs: Set<String> = ["coding.read-buffer", "coding.read-selection"]
        var seen: Set<String> = []
        for skill in coding.skills where readOnlySkillIDs.contains(skill.id.rawValue) {
            seen.insert(skill.id.rawValue)
            #expect(skill.requirements.perceptions.isEmpty, """
                \(skill.id.rawValue) must not hard-require any perception — a \
                momentarily unresolved fact must never exclude a read-only Skill \
                from the roster outright. Found: \(skill.requirements.perceptions)
                """)
            #expect(skill.requirements.optionalPerceptions.contains(.codeWorkspaceFocus), """
                \(skill.id.rawValue) must still declare code-workspace-focus as OPTIONAL, \
                so routing can prefer it without being able to block on it.
                """)
        }
        #expect(seen == readOnlySkillIDs, "both read-only code-surface Skills must be present to check")

        // THE CHORD SKILLS ARE UNTOUCHED, on purpose — this plan's scope is
        // just the two read-only Skills. If a future edit loosens these too,
        // that's a deliberate, separate decision this test should not silently
        // ratify by staying green.
        let chordSkillIDs: Set<String> = [
            "coding.build-project", "coding.run-project", "coding.test-project",
            "coding.save-all", "coding.stop-execution",
        ]
        for skill in coding.skills where chordSkillIDs.contains(skill.id.rawValue) {
            #expect(skill.requirements.perceptions.contains(.codeWorkspaceFocus), """
                \(skill.id.rawValue) still hard-requires code-workspace-focus — \
                out of scope for this fix, unchanged by design.
                """)
        }
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
