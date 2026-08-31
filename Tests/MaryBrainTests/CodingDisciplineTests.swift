//
//  CodingDisciplineTests.swift
//  MaryBrainTests
//
//  WHAT: Shipped coding.mary × xcode.mary — join, focus, conflict, read-only gates.
//  OUT:  PluginCompiler + AbilityRosterArbitrator + CognitivePrimitiveCatalog
//  PIN:  Place focus is WorkspaceFocus, not alphabetical ability ids
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
                    placeClass: .workspace,
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
                    placeClass: .workspace, displayName: "Xcode",
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
                    world: AmbientWorld(store: ambient),
                    contextProvider: { AbilityExecutionContext(projects: [:]) })
                let offered = Set(runtime.schemas.map(\.name))
                #expect(offered.contains("build_project"),
                        "coding's own chord Skills must survive the ability conflict")
                #expect(offered.contains("search_project")
                    || offered.contains("search_corpus"),
                        "a project-corpus search Skill must still be admitted — a tie, not a loss")
                #expect(offered.contains("read_buffer"))
                #expect(offered.contains("read_selection"))
                #expect(offered.contains("list_declarations"))
            }
        }
    }

    /// [CORPUS Q] THE OVER-ADMISSION THE TIE FIX ABOVE ITSELF INTRODUCED.
    ///
    /// The tie this suite pins above solved a real loss (Coding losing
    /// outright) by making `writing.mary`'s carve-out arm — `all(workspace
    /// Family=="coding", targetClass=="writing-project")` — admit the WHOLE
    /// Writing Ability whenever Xcode is fronted, because `xcode.mary`
    /// unconditionally declares `writing-project` in its own `targetClasses`
    /// (`Corpus G`, for the corpus lane's sake). Ability-level admission is
    /// all-or-nothing: once Writing is active, every one of its Skills that
    /// declares no NARROWER Skill-level `eligibility` of its own is offered
    /// too — not just the four corpus-read Skills the arm exists for.
    /// Confirmed live (`mary-corpus-probe`-equivalent, driven through this
    /// exact harness) before this fix: `type_at_cursor`, `resume_typing`,
    /// `start_dictation`/`stop_dictation`, `delete_passage`/`find_passage`/
    /// `insert_passage`/`replace_passage`, `revert_last_edit`, and
    /// `add_corpus_container`/`add_corpus_item`/`move_corpus_item`/
    /// `trash_corpus_item` were ALL offered alongside `build_project` on
    /// every single Xcode turn, regardless of utterance — directly
    /// contradicting `xcode.mary`'s own doctrine, "NO PROSE SURFACE,
    /// deliberately."
    ///
    /// THE FIX gives each of those Skills its own `eligibility` requiring
    /// `not(workspaceFamily=="coding")` (merged via `all` where a Skill
    /// already carried one, e.g. `revise_selection`'s `hasInteraction`
    /// gate) — the same per-Skill narrowing mechanism `compose-draft`
    /// (`intent=="compose"`) and `revise-selection` already used to sit
    /// below the Ability's own blanket admission. The Ability-level arm
    /// itself, and its mirror on `coding.mary`, are UNCHANGED: they still
    /// admit Writing (so the four corpus Skills stay reachable) and still
    /// keep the tie (so Coding still never loses). Only the blast radius of
    /// that admission is narrowed, Skill by Skill — never the ambient
    /// signal the plan's two alternatives ((a) a second targetClass, (b) a
    /// `proseSurface` condition on the tie arm) both would have had to
    /// touch, and both of which were rejected: renaming the targetClass
    /// leaves the SAME single ability-wide admission, so it does not shrink
    /// what a wholesale admission exposes; requiring `proseSurface` on the
    /// tie arm makes it — and therefore Writing's admission for Xcode at
    /// all — never fire, since Xcode declares no `proseSurface` by design,
    /// which would silently kill `search_corpus`/`read_corpus_outline`/
    /// `read_corpus_document`/`corpus_progress` for Xcode too (`Corpus G`'s
    /// whole point).
    ///
    /// `revise_selection` is asserted absent even THOUGH this fixture's
    /// utterance carries no `interaction.text-selection` — the point is
    /// that it must never leak in Xcode by ability-admission ALONE, the
    /// same standing this suite already holds `type_at_cursor` to.
    @Test func aCodingTurnInXcodeOffersNoWritingSkill() async throws {
        guard InstalledPackages.installed() != nil else { return }
        let xcode = try loadRootPackage("xcode")
        let coding = try loadRootPackage("coding")
        let writing = try loadRootPackage("writing")
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
                observers: MaryAdapterCatalog.observers()),
            plugins: compilation)

        let ambient = AmbientContextStore()

        try await AmbientApplicationIndexProvider.$scoped.withValue(
            AmbientApplicationRoster([
                ApplicationRegistration(
                    id: "xcode", profile: xcodeProfile,
                    bundleIdentifiers: ["com.apple.dt.Xcode"],
                    placeClass: .workspace, displayName: "Xcode",
                    perception: perception),
            ])
        ) {
            let route = AmbientEngine.resolve(AmbientEngine.Inputs(
                utterance: "add a comment to this function",
                leadApplicationID: "xcode",
                profiles: [xcodeProfile]))
            #expect(route.leadPlace?.ability?.rawValue == "coding",
                    "the turn must actually read as a coding workspace for this to be a real test")
            ambient.noteUtterance("add a comment to this function")
            ambient.noteRoute(route)

            try await AbilityTurnContext.$snapshot.withValue(snapshot) {
                let runtime = AbilityRuntime(
                    plugins: MaryAdapterCatalog.adapters(),
                    world: AmbientWorld(store: ambient),
                    contextProvider: { AbilityExecutionContext(projects: [:]) })
                let offered = Set(runtime.schemas.map(\.name))

                // CODING SURVIVES, unchanged from the test above.
                #expect(offered.contains("build_project"))
                #expect(offered.contains("run_project"))
                #expect(offered.contains("test_project"))
                #expect(offered.contains("save_all"))
                #expect(offered.contains("stop_execution"))

                // THE CORPUS LANE SURVIVES — `Corpus G`'s whole point, and
                // exactly what a `proseSurface`-gated tie arm would have lost.
                #expect(offered.contains("search_project")
                    || offered.contains("search_corpus"))
                #expect(offered.contains("project_outline")
                    || offered.contains("read_corpus_outline"))
                #expect(offered.contains("read_corpus_document"))
                #expect(offered.contains("corpus_progress"))

                // BUT NO WRITING PROSE-SURFACE SKILL LEAKS IN. This is the
                // actual bug: before this fix every one of these showed up
                // in `offered` on this exact turn.
                let writingProseSkills = [
                    "type_at_cursor", "revise_selection", "resume_typing",
                    "start_dictation", "stop_dictation", "delete_passage",
                    "find_passage", "insert_passage", "replace_passage",
                    "revert_last_edit", "add_corpus_container",
                    "add_corpus_item", "move_corpus_item", "trash_corpus_item",
                    "list_documents", "read_document", "create_document",
                ]
                for skill in writingProseSkills {
                    #expect(!offered.contains(skill), """
                        \(skill) must not be offered on an unambiguous coding \
                        turn in Xcode — Xcode has no prose surface, by design.
                        """)
                }
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
    ///
    /// `coding.list-declarations` ([Corpus T]) JOINS THE SAME SET — it is
    /// the same shape of read-only, `.native`-bound Skill `read_buffer`/
    /// `read_selection` already are, applying the exact `[Corpus L]`
    /// reasoning this test exists to pin rather than re-deriving a third
    /// answer for it.
    @Test func readOnlyCodeSurfaceSkillsDoNotHardGateOnWorkspaceFocus() throws {
        guard InstalledPackages.installed() != nil else { return }
        let coding = try loadRootPackage("coding")

        let readOnlySkillIDs: Set<String> = [
            "coding.read-buffer", "coding.read-selection", "coding.list-declarations",
        ]
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

    // MARK: - [Corpus Q] revise_selection specifically, at the predicate level

    /// THE NARROWER, PREDICATE-LEVEL PIN for the same fix. `revise_selection`
    /// already carried its own `hasInteraction("interaction.text-selection")`
    /// Skill-level eligibility — which does not mention workspace at all, so
    /// a genuine selection made inside Xcode (not exercised by the
    /// full-roster test above, which supplies no Interaction) would have
    /// satisfied it regardless of Ability admission's cause. This drives
    /// `AbilityRoutingEvaluator.isEligible` directly against the shipped
    /// predicate tree with a live `interaction.text-selection` present, so
    /// the fix is pinned even under the one condition the roster test can't
    /// exercise. Writing's own Ability-level admission stays true — the
    /// corpus arm this suite already proved must survive — while the Skill
    /// itself now additionally requires `not(workspaceFamily=="coding")`.
    @Test func reviseSelectionStaysExcludedFromCodingEvenWithALiveSelection() throws {
        guard InstalledPackages.installed() != nil else { return }
        let writing = try loadRootPackage("writing")
        let reviseSelection = try #require(
            writing.skills.first { $0.id.rawValue == "writing.revise-selection" })

        let context = AbilityRoutingContext(
            targetClasses: ["writing-project", "code-workspace"],
            interactions: [InteractionID("interaction.text-selection")],
            workspaceFamily: "coding")

        #expect(
            AbilityRoutingEvaluator.isEligible(writing.ability.routing, in: context),
            "the corpus arm must still admit Writing's Ability")
        #expect(
            !AbilityRoutingEvaluator.isEligible(reviseSelection.routing, in: context),
            "revise_selection must stay excluded from a coding workspace even with a live selection")
    }

    /// Exact-match lookup is the security boundary: coding's revision
    /// primitive cannot be reached by borrowing writing's invocation.
    @Test func codeRevisionIsScopedToCodingsOwnSkillIdentity() {
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .coding,
                skillID: "coding.revise-selection",
                invocationName: "revise_code_selection"))?.primitive
            == .reviseCodeSelection)
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .writing,
                skillID: "coding.revise-selection",
                invocationName: "revise_code_selection")) == nil)
        #expect(CognitivePrimitiveCatalog.contract(
            for: Self.runtimeSkill(
                ability: .coding,
                skillID: "coding.revise-selection",
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
                id: "tests.code-revision",
                version: "1.0.0",
                publisher: "tests",
                summary: "revise_code_selection identity fixture."),
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
