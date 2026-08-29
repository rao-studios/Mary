//
//  EditorSightTests.swift
//  MaryBrainTests
//
//  THE SPEAKING LANE ALREADY HOLDS THE EDITOR WINDOW. A coding-led turn
//  used to arrive with `CorpusObserver`'s identity line as `leadContext`
//  and `wouldServeLook()` true (the targeted read was keyed
//  `"code-surface"` while focus owned `"xcode"`), so "can you see this
//  code" invited a screenshot of Mary's own window and the blindness
//  clause. These two pins are that inversion: the caret excerpt wins the
//  arbiter, and an Xcode lead declines the pixel look.
//

import Foundation
import MaryFoundationTestSupport
import Testing
@testable import MaryAmbient
@testable import MaryBrain
@testable import MaryFoundation
@testable import MaryPlugin

@Suite struct EditorSightTests {

    private var xcode: AmbientPlace { .application("xcode") }

    private var liveWindow: String {
        CodeCursorScope.liveWork(
            editorName: "Xcode",
            fileName: "VoicePipeline+Turn.swift",
            content: CodeCursorScope.content(
                .init(
                    line: 112,
                    chain: ["submitTurn"],
                    excerpt: "for try await event in events {")))
    }

    // MARK: - Arbiter

    /// THE IDENTITY LINE MUST NOT OCCUPY `leadContext`. Both observers
    /// speak for the same place; the one with a full section — the caret
    /// window — leads, and the path is not a second full section.
    @Test func aCaretExcerptBeatsACorpusIdentityLine() {
        let sections = WorkspaceFocusArbiter.sections(
            focus: .coding,
            contributions: [
                .init(
                    place: xcode,
                    discipline: .coding,
                    full: [],
                    ambient: "Working in Mary — Sources/VoicePipeline+Turn.swift"),
                .init(
                    place: xcode,
                    discipline: .coding,
                    full: [liveWindow],
                    ambient: "In Xcode: VoicePipeline+Turn.swift",
                    liveDocumentIsWhole: false),
            ])
        #expect(sections.leadPlace == xcode)
        #expect(sections.leadContext.count == 1)
        let lead = sections.leadContext[0]
        #expect(lead.contains("Current file:"))
        #expect(lead.contains("VoicePipeline+Turn.swift"))
        #expect(lead.contains("Cursor scope: submitTurn (line 112)"))
        #expect(lead.contains("What they see (from line 112):"))
        #expect(lead.contains("for try await event in events {"))
        #expect(!lead.contains("Working in Mary"))
    }

    // MARK: - Pixel look

    @Test func aCodeSurfaceApplicationDeclinesThePixelLook() {
        let support = CodeSurfaceSupport()
        support.reconcile([
            CodeSurfaceRegistration(
                applicationID: "xcode",
                bundleIdentifiers: ["com.apple.dt.Xcode"],
                displayName: "Xcode",
                schema: PackageFixtures.codeSurface),
        ])
        let eyed = AbilityRuntime(
            plugins: [
                CodeSurfaceAdapter(support: support),
                LookingPlugin { _ in SkillOutcome(ok: true, summary: "looked") },
            ],
            focusProvider: { "xcode" }
        ) { AbilityExecutionContext(projects: [:]) }
        #expect(eyed.wouldServeLook() == false)

        let unled = AbilityRuntime(
            plugins: [
                CodeSurfaceAdapter(support: support),
                LookingPlugin { _ in SkillOutcome(ok: true, summary: "looked") },
            ],
            focusProvider: { nil }
        ) { AbilityExecutionContext(projects: [:]) }
        #expect(unled.wouldServeLook() == true)
    }
}
