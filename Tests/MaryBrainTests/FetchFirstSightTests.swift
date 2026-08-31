//
//  FetchFirstSightTests.swift
//  MaryBrainTests
//
//  WHAT: wouldServeLook is not vetoed by targetedRead; fetch-first prefers selection.
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
            ]
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

    @Test func targetedReadDoesNotVetoLook() {
        let ambient = AmbientContextStore()
        let runtime = AbilityRuntime(
            plugins: [SightAdapter(dispatched: Dispatched())],
            focusProvider: { "xcode" },
            world: AmbientWorld(store: ambient),
            contextProvider: { AbilityExecutionContext(projects: [:]) })
        #expect(runtime.wouldServeLook())
    }

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
        let passage = await runtime.fetchDeclaredEditorSight(query: "Let's take a look at this code")
        #expect(passage == "func parameters() {}")
        #expect(dispatched.snapshot() == ["read_selection"])
        #expect(!dispatched.snapshot().contains("look_at_screen"))
        #expect(!dispatched.snapshot().contains("read_symbol"))
    }

    @Test func lookFirstNudgeNamesEditorReads() {
        #expect(MaryPrompts.lookFirstNudge.contains("read_selection"))
        #expect(MaryPrompts.lookFirstNudge.contains("read_buffer"))
        #expect(MaryPrompts.lookFirstNudge.contains("read_document"))
        #expect(MaryPrompts.lookFirstNudge.contains("look_at_screen"))
    }
}
