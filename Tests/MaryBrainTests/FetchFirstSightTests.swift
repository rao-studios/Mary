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
            tier: .activation, attention: .applications,
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
        await AmbientApplicationIndexProvider.$scoped.withValue(Self.codingIndex()) {
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
            tier: .activation, attention: .applications,
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
        await AmbientApplicationIndexProvider.$scoped.withValue(Self.codingIndex()) {
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
            tier: .activation, attention: .applications,
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
        await AmbientApplicationIndexProvider.$scoped.withValue(Self.writingIndex()) {
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

    @Test func lookFirstNudgeNamesEditorReads() {
        #expect(MaryPrompts.lookFirstNudge.contains("read_selection"))
        #expect(MaryPrompts.lookFirstNudge.contains("read_buffer"))
        #expect(MaryPrompts.lookFirstNudge.contains("read_document"))
        #expect(MaryPrompts.lookFirstNudge.contains("look_at_screen"))
    }
}
