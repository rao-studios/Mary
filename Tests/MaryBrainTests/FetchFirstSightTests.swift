//
//  FetchFirstSightTests.swift
//  MaryBrainTests
//
//  WHAT: A targeted read VETOES look; fetch-first prefers selection, then
//        the lead's OWN declared discipline (read_buffer / read_document),
//        never a receipt, never current_file.
//  OUT:  AbilityRuntime
//

import Foundation
import Testing
import MaryAmbient
import MaryFoundation
@testable import MaryPlugin
@testable import MaryBrain

@Suite struct FetchFirstSightTests {

    private struct SightAdapter: MaryAdapter {
        let name = "code-surface"
        let summary = "A fixture."
        var targetedRead: (binding: String, parameter: String)? { ("read_symbol", "symbol") }
        var targetedReadAliases: [String] { ["xcode"] }
        let dispatched: Dispatched
        var extraBindings: [SkillBinding] = []
        var skillBindings: [SkillBinding] {
            let dispatched = dispatched
            return [
                SkillBinding(
                    name: "look_at_screen",
                    description: "Look.",
                    parameters: [],
                    access: .read,
                    backing: .native { _, _ in
                        dispatched.note("look_at_screen")
                        return SkillOutcome(ok: true, summary: "a window")
                    }),
                SkillBinding(
                    name: "read_selection",
                    description: "Read highlight.",
                    parameters: [],
                    access: .read,
                    backing: .native { _, _ in
                        dispatched.note("read_selection")
                        return SkillOutcome(ok: true, summary: "func parameters() {}")
                    }),
                SkillBinding(
                    name: "read_symbol",
                    description: "Read a symbol.",
                    parameters: [
                        .init(name: "symbol", type: "string", description: "", required: true)
                    ],
                    access: .read,
                    backing: .native { _, _ in
                        dispatched.note("read_symbol")
                        return SkillOutcome(ok: true, summary: "symbol body")
                    }),
            ] + extraBindings
        }
    }

    private final class Dispatched: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func note(_ name: String) {
            lock.lock(); names.append(name); lock.unlock()
        }
        func snapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return names
        }
    }

    /// A read-skill fixture that answers with a fixed summary — a receipt
    /// when short, a real passage when it isn't.
    private static func summaryBinding(
        _ name: String, summary: String, dispatched: Dispatched
    ) -> SkillBinding {
        SkillBinding(
            name: name,
            description: "Fixture.",
            parameters: [],
            access: .read,
            backing: .native { _, _ in
                dispatched.note(name)
                return SkillOutcome(ok: true, summary: summary)
            })
    }

    private static func codingIndex() -> AmbientApplicationRoster {
        AmbientApplicationRoster([
            ApplicationRegistration(
                id: "xcode",
                profile: ApplicationProfile(
                    id: "xcode", title: "Xcode", summary: "IDE.", abilities: [.coding]),
                bundleIdentifiers: ["com.apple.dt.Xcode"],
                placeClass: .workspace,
                displayName: "Xcode"),
        ])
    }

    private static func writingIndex() -> AmbientApplicationRoster {
        AmbientApplicationRoster([
            ApplicationRegistration(
                id: "notes",
                profile: ApplicationProfile(
                    id: "notes", title: "Notes", summary: "Notes app.", abilities: [.writing]),
                bundleIdentifiers: ["com.apple.Notes"],
                placeClass: .workspace,
                displayName: "Notes"),
        ])
    }

    // MARK: - wouldServeLook

    /// An eyed world with a targeted read in hand declines the look — a
    /// screenshot of a surface Mary can already read exactly is a picture of
    /// text, not new sight. (Flipped from the prior doctrine, which vetoed
    /// nothing — see AbilityRuntime.wouldServeLook.)
    @Test func targetedReadVetoesLook() {
        let ambient = AmbientContextStore()
        let runtime = AbilityRuntime(
            plugins: [SightAdapter(dispatched: Dispatched())],
            focusProvider: { "xcode" },
            world: AmbientWorld(store: ambient),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        #expect(!runtime.wouldServeLook())
    }

    // MARK: - The ladder

    @Test func fetchFirstPrefersSelectionReadOverLook() async {
        let ambient = AmbientContextStore()
        _ = ambient.recordSelection(.init(
            attention: .applications,
            application: "xcode",
            applicationID: "com.apple.dt.Xcode",
            processID: 1,
            text: "func parameters() {}",
            subject: "AbilityRuntime.swift",
            range: 0..<20,
            channel: .sourcePoll,
            sourceEvidence: .exactElement))
        let dispatched = Dispatched()
        let runtime = AbilityRuntime(
            plugins: [SightAdapter(dispatched: dispatched)],
            focusProvider: { "xcode" },
            world: AmbientWorld(store: ambient),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        let sight = await runtime.fetchDeclaredEditorSight(query: "Let's take a look at this code")
        #expect(sight?.passage == "func parameters() {}")
        #expect(sight?.isRead == true)
        #expect(dispatched.snapshot() == ["read_selection"])
        #expect(!dispatched.snapshot().contains("look_at_screen"))
        #expect(!dispatched.snapshot().contains("read_symbol"))
    }

    /// `current_file`'s summary is a RECEIPT ("Looking at Foo.swift in
    /// Proj.") — fetch-first must not serve it as sight. A coding lead's
    /// `read_buffer` answering the same one-line shape falls through to the
    /// next rung exactly as if it had said nothing.
    @Test func receiptSummaryFallsThroughToNextRung() async {
        let ambient = AmbientContextStore()
        ambient.noteWorld(AmbientWorld.Snapshot(
            sense: .workspace, attention: .applications,
            applicationID: "com.apple.dt.Xcode"))
        let dispatched = Dispatched()
        let adapter = SightAdapter(
            dispatched: dispatched,
            extraBindings: [
                Self.summaryBinding(
                    "read_buffer", summary: "Looking at Foo.swift in Proj.", dispatched: dispatched),
                Self.summaryBinding(
                    "read_document",
                    summary: "func parameters() {\n    // real body\n}", dispatched: dispatched),
            ])
        await withScopedWorld(roster: Self.codingIndex()) {
            let runtime = AbilityRuntime(
                plugins: [adapter],
                focusProvider: { "xcode" },
                world: AmbientWorld(store: ambient),
                contextProvider: { AbilityExecutionContext(projects: [:]) })
            let sight = await runtime.fetchDeclaredEditorSight(query: nil)
            #expect(sight?.passage == "func parameters() {\n    // real body\n}")
            #expect(sight?.isRead == true)
            #expect(dispatched.snapshot() == ["read_buffer", "read_document"])
        }
    }

    /// A `.coding` lead reads its live BUFFER — never the dropped
    /// `current_file` receipt, and never a look when a read served.
    @Test func codingLeadReadsBufferNeverCurrentFileOrLook() async {
        let ambient = AmbientContextStore()
        ambient.noteWorld(AmbientWorld.Snapshot(
            sense: .workspace, attention: .applications,
            applicationID: "com.apple.dt.Xcode"))
        let dispatched = Dispatched()
        let adapter = SightAdapter(
            dispatched: dispatched,
            extraBindings: [
                Self.summaryBinding(
                    "read_buffer", summary: "func foo() {\n    bar()\n}", dispatched: dispatched),
                Self.summaryBinding(
                    "current_file", summary: "Looking at Foo.swift in Proj.", dispatched: dispatched),
                Self.summaryBinding(
                    "read_document", summary: "should not be reached", dispatched: dispatched),
            ])
        await withScopedWorld(roster: Self.codingIndex()) {
            let runtime = AbilityRuntime(
                plugins: [adapter],
                focusProvider: { "xcode" },
                world: AmbientWorld(store: ambient),
                contextProvider: { AbilityExecutionContext(projects: [:]) })
            let sight = await runtime.fetchDeclaredEditorSight(query: nil)
            #expect(sight?.passage == "func foo() {\n    bar()\n}")
            #expect(sight?.isRead == true)
            #expect(dispatched.snapshot() == ["read_buffer"])
            #expect(!dispatched.snapshot().contains("current_file"))
            #expect(!dispatched.snapshot().contains("look_at_screen"))
        }
    }

    /// A `.writing` lead reads its DOCUMENT, never the coding family's buffer.
    @Test func writingLeadReadsDocumentNeverBuffer() async {
        let ambient = AmbientContextStore()
        ambient.noteWorld(AmbientWorld.Snapshot(
            sense: .workspace, attention: .applications,
            applicationID: "com.apple.Notes"))
        let dispatched = Dispatched()
        let adapter = SightAdapter(
            dispatched: dispatched,
            extraBindings: [
                Self.summaryBinding(
                    "read_buffer", summary: "should not be reached", dispatched: dispatched),
                Self.summaryBinding(
                    "read_document",
                    summary: "Once upon a time,\nthere was a paragraph.", dispatched: dispatched),
            ])
        await withScopedWorld(roster: Self.writingIndex()) {
            let runtime = AbilityRuntime(
                plugins: [adapter],
                focusProvider: { "notes" },
                world: AmbientWorld(store: ambient),
                contextProvider: { AbilityExecutionContext(projects: [:]) })
            let sight = await runtime.fetchDeclaredEditorSight(query: nil)
            #expect(sight?.passage == "Once upon a time,\nthere was a paragraph.")
            #expect(sight?.isRead == true)
            #expect(dispatched.snapshot() == ["read_document"])
        }
    }

    /// A ROUTE THAT REJECTED THE SELECTION IS ANSWERED, not re-asked. Inside a
    /// turn the sight ladder reads `route.routedWorld`; when the route did not
    /// accept the standing highlight that is nil, and re-reading the store here
    /// would hand the rejected selection straight back as sight.
    @Test func aRejectedSelectionIsNotServedAsSight() async {
        let ambient = AmbientContextStore()
        // A real highlight STANDS in the store — `fetchFirstPrefersSelectionReadOverLook`
        // is the same fixture and proves this one gets served when the route accepts it.
        _ = ambient.recordSelection(.init(
            attention: .applications,
            application: "xcode",
            applicationID: "com.apple.dt.Xcode",
            processID: 1,
            text: "func parameters() {}",
            subject: "AbilityRuntime.swift",
            range: 0..<20,
            channel: .sourcePoll,
            sourceEvidence: .exactElement))
        let dispatched = Dispatched()
        let adapter = SightAdapter(dispatched: dispatched)
        // ...but this turn's route did not take it as the referent.
        let standing = AmbientWorld.Snapshot(
            sense: .selection,
            attention: .applications,
            applicationID: "com.apple.dt.Xcode",
            selectedText: "func parameters() {}")
        let route = AmbientRoute(
            intent: .converse, decidedBy: .none,
            world: standing, selectionDefinesTurn: false)
        #expect(route.routedWorld == nil, "precondition: the route rejected it")

        let state = AmbientRouteTurnState()
        state.note(route)
        await AmbientRouteTurnContext.$state.withValue(state) {
            await withScopedWorld(roster: Self.codingIndex()) {
                let runtime = AbilityRuntime(
                    plugins: [adapter],
                    focusProvider: { "xcode" },
                    world: AmbientWorld(store: ambient),
                    contextProvider: { AbilityExecutionContext(projects: [:]) })
                _ = await runtime.fetchDeclaredEditorSight(query: nil)
                #expect(!dispatched.snapshot().contains("read_selection"))
            }
        }
    }

    @Test func lookFirstNudgeNamesEditorReads() {
        #expect(MaryPrompts.lookFirstNudge.contains("read_selection"))
        #expect(MaryPrompts.lookFirstNudge.contains("read_buffer"))
        #expect(MaryPrompts.lookFirstNudge.contains("read_document"))
        #expect(MaryPrompts.lookFirstNudge.contains("look_at_screen"))
    }

    // MARK: - The roster gates the model, not Mary's own eyes

    /// THE LIVE BUG THIS PINS: a highlight on screen, "what do you think about
    /// this code", and `read_selection` never ran.
    ///
    /// The turn loop asks the dispatcher for `schemaCount` before `seerTurn`,
    /// which PROJECTS this turn's roster — and in the embedding regime a Skill
    /// enters that roster only when the utterance embeds near its own authored
    /// corpus. A judgment question about code does not embed near "Read the
    /// Selection", so the fetch-first pre-read dispatched straight into
    /// `offerLedgerFailure` and came back blocked. Mary then answered a
    /// question about code having read none, which is where "paste the code
    /// here" came from — with the code highlighted in front of her.
    ///
    /// A PRE-READ IS NOT THE MODEL REACHING FOR AN UNOFFERED SKILL. It is Mary
    /// deciding, from the route and the world, to look at the work before she
    /// speaks. The ledger yields to that and to nothing else: the same call
    /// made by the model, in the same turn, is still refused.
    @Test func maryOwnPreReadOutrunsTheTurnRoster() async throws {
        let snapshot = try #require(Self.rosterWithholdingReadSelection())
        let ambient = AmbientContextStore()
        ambient.noteUtterance(Self.judgmentQuestion)
        _ = ambient.recordSelection(.init(
            attention: .applications,
            application: "xcode",
            applicationID: "com.apple.dt.Xcode",
            processID: 1,
            text: "func parameters() {}",
            subject: "AbilityRuntime.swift",
            range: 0..<20,
            channel: .sourcePoll,
            sourceEvidence: .exactElement))
        let dispatched = Dispatched()
        let runtime = AbilityRuntime(
            plugins: [SightAdapter(dispatched: dispatched)],
            focusProvider: { "xcode" },
            world: AmbientWorld(store: ambient),
            contextProvider: { AbilityExecutionContext(projects: [:]) })

        await AbilityTurnContext.$snapshot.withValue(snapshot) {
            // The turn loop's own first question, and the thing that arms the
            // ledger. Without it there is no gate to outrun.
            _ = runtime.schemaCount

            let sight = await runtime.fetchDeclaredEditorSight(query: Self.judgmentQuestion)
            #expect(sight?.passage == "func parameters() {}")
            #expect(sight?.isRead == true)
            #expect(dispatched.snapshot() == ["read_selection"])

            // ...and the model asking for the very same Skill, in the very
            // same turn, is still refused by the very same ledger.
            let refused = await runtime.dispatch(
                name: "read_selection", argumentsJSON: "{}")
            #expect(!refused.ok)
            #expect(refused.status == .blocked)
            #expect(refused.summary.contains("roster"))
            #expect(dispatched.snapshot() == ["read_selection"], "blocked before the binding ran")
        }
    }

    /// The words the user actually said, and the reason the roster withholds:
    /// nothing in this sentence resembles the Skill's authored corpus.
    private static let judgmentQuestion = "what do you think about this code"

    /// A frozen registry whose embedding roster cannot admit `read_selection`
    /// for `judgmentQuestion` — the shape of a real turn in an editor.
    private static func rosterWithholdingReadSelection() -> AbilityRuntimeSnapshot? {
        let package = MaryAbilityPackage(
            package: .init(
                id: "tests.eyes",
                version: "1.0.0",
                publisher: "Mary tests",
                summary: "A discipline that reads a highlight."),
            ability: .init(
                id: "tests.eyes",
                title: "Eyes",
                summary: "Reads what is selected.",
                tint: "#334455",
                skills: ["tests.eyes.read-selection"],
                paradigm: .discipline),
            skills: [
                SkillSchema(
                    id: "tests.eyes.read-selection",
                    title: "Read the Selection",
                    summary: "Read the text currently highlighted in the editor.",
                    kind: .effectful,
                    execution: .init(
                        kind: .binding,
                        bindings: [.init(
                            adapterID: "code-surface",
                            operation: "read_selection",
                            preference: 100)]),
                    modelExposure: .init(invocationName: "read_selection"))
            ])
        let record = AbilityPackageRecord(
            package: package,
            source: .sourceTree,
            sourceURL: URL(fileURLWithPath: "/tmp/tests.eyes.mary"),
            validation: .init(),
            rawData: Data())
        // Knows the Skill's own corpus and NOTHING else — so the utterance
        // vectorizes to nil and the Skill scores no affinity at all.
        let vectorizer = KnownTermsVectorizer(terms: [
            "Read the Selection",
            "Read the text currently highlighted in the editor.",
            "read selection",
            "tests eyes read selection",
        ])
        guard let skills = SemanticSkillRequestIndex.build(
            records: [record], vectorizer: vectorizer)
        else { return nil }
        let manifest = InstalledAdapterManifest(
            adapterID: AdapterID("code-surface"),
            title: "Code Surface",
            transport: .native,
            operations: [InstalledAdapterBinding(
                adapterID: AdapterID("code-surface"), operation: "read_selection")])
        return AbilityRuntimeSnapshot(
            records: [record],
            validation: .init(),
            adapterManifests: [manifest],
            semanticSkillIndex: skills)
    }

    /// One orthogonal basis vector per known term; anything else is nil, so a
    /// miss is a miss rather than a stale neighbour.
    private struct KnownTermsVectorizer: AmbientTextVectorizer {
        let indices: [String: Int]

        init(terms: [String]) {
            var map: [String: Int] = [:]
            for (index, term) in terms.enumerated() {
                map[term.lowercased()] = index
            }
            indices = map
        }

        func vector(for text: String) -> [Float]? {
            guard let index = indices[text.lowercased()] else { return nil }
            var vector = [Float](repeating: 0, count: max(indices.count, 1))
            vector[index] = 1
            return vector
        }
    }
}
