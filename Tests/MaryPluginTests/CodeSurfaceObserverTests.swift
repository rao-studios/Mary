//
//  CodeSurfaceObserverTests.swift
//  MaryPluginTests
//
//  WHAT ADDING AN OBSERVER TO THE CATALOG IS AND IS NOT ALLOWED TO CHANGE.
//
//  The standing cursor lane's poll needs a live editor and belongs to the
//  probe (`mary-corpus-probe project --dispatch-code-surface`). What belongs
//  here is the part that has nothing to do with Accessibility and everything
//  to do with the rest of the system: an observer joins a roster whose
//  manifests decide Skill readiness for EVERY package, writing ones included,
//  and the reason this one is safe to add is that it claims nothing new.
//

import Foundation
import MaryAmbient
import MaryFoundation
import XCTest
@testable import MaryPlugin

final class CodeSurfaceObserverTests: XCTestCase {

    private var observers: [any MaryObserver] { MaryAdapterCatalog.observers() }

    func testTheCursorObserverIsInTheShippedRoster() {
        XCTAssertTrue(
            observers.contains { $0.id == CodeSurfaceObserver.shared.id },
            "the catalog must carry the observer, or nothing ever polls")
    }

    /// IT CLAIMS NOTHING THE ROSTER DID NOT ALREADY CLAIM — the whole reason
    /// adding it cannot move another package's Skill readiness. It declares
    /// `.workspace` (which is how `installBrainConfiguration`'s turn preparer
    /// knows to refresh it before a turn), and `perception.workspace-focus`
    /// was already provided by the surface observer and the corpus observer
    /// both. So the roster's UNION of provided Perceptions and Interactions
    /// is byte-identical with and without it, and a readiness join computed
    /// over that union cannot notice.
    func testItAddsNoPerceptionOrInteractionTheRosterDidNotAlreadyProvide() {
        func union(
            _ observers: [any MaryObserver]
        ) -> (perceptions: Set<PerceptionID>, interactions: Set<InteractionID>) {
            var perceptions: Set<PerceptionID> = []
            var interactions: Set<InteractionID> = []
            for observer in observers {
                perceptions.formUnion(observer.providedPerceptions)
                interactions.formUnion(observer.providedInteractions)
            }
            return (perceptions, interactions)
        }
        let withCursor = union(observers)
        let without = union(observers.filter { $0.id != CodeSurfaceObserver.shared.id })
        XCTAssertEqual(withCursor.perceptions, without.perceptions)
        XCTAssertEqual(withCursor.interactions, without.interactions)
        XCTAssertFalse(
            without.perceptions.isEmpty,
            "a vacuous pass — the roster must really provide workspace focus")
    }

    /// IT SPEAKS FOR A PLACE ONLY AFTER A CARET IS STANDING. A fresh
    /// observer must not enter the arbiter empty and steal a writing lead.
    func testAFreshObserverHasNothingToSayToTheArbiter() {
        let observer = CodeSurfaceObserver()
        XCTAssertNil(observer.observedPlace)
        XCTAssertNil(observer.ambientLine)
        XCTAssertNil(observer.promptContribution())
    }

    /// A POLL WITH NO CODE EDITOR IN FRONT PUBLISHES NOTHING — the property
    /// that keeps this lane out of the writing lane's way. A test runner is
    /// never a declared code surface, so this exercises the real early
    /// return, and the store it is handed is its own.
    func testAPollWithNoDeclaredCodeSurfaceInFrontHoldsNothing() {
        let store = AmbientContextStore()
        let observer = CodeSurfaceObserver(
            store: store, support: CodeSurfaceSupport(), corpus: CorpusSupport())
        observer.pollOnce()
        XCTAssertTrue(store.facts().filter { $0.slot == .cursor }.isEmpty)
    }

    /// THE SPEAKING LANE GETS THE WINDOW, not a path. After a caret is
    /// standing this observer votes for the application and contributes the
    /// Bonnie-shaped excerpt — the inversion that used to leave
    /// `CorpusObserver`'s identity line as `leadContext`.
    func testAStandingCaretSpeaksTheLiveWindowToTheArbiter() {
        let observer = CodeSurfaceObserver()
        let live = CodeCursorScope.liveWork(
            editorName: "Xcode",
            fileName: "VoicePipeline+Turn.swift",
            content: CodeCursorScope.content(
                .init(line: 112, chain: ["submitTurn"], excerpt: "for try await event in events {")))
        observer.adoptStandingCaretForTests(
            place: .application("xcode"),
            line: "In Xcode: VoicePipeline+Turn.swift",
            live: live)
        XCTAssertEqual(observer.observedPlace, .application("xcode"))
        XCTAssertEqual(observer.ambientLine, "In Xcode: VoicePipeline+Turn.swift")
        XCTAssertEqual(observer.promptContribution(), live)
        XCTAssertFalse(observer.holdsWholeDocument)
    }

    // MARK: - Standing coding workspace

    private var xcodeSurface: CodeSurfaceRegistration {
        CodeSurfaceRegistration(
            applicationID: "xcode",
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            displayName: "Xcode",
            schema: PluginCodeSurfaceSchema(handlePrefix: "C"))
    }

    private var vscodeSurface: CodeSurfaceRegistration {
        CodeSurfaceRegistration(
            applicationID: "vscode",
            bundleIdentifiers: ["com.microsoft.VSCode"],
            displayName: "VS Code",
            schema: PluginCodeSurfaceSchema(handlePrefix: "C"))
    }

    private var xcodeProcess: CodeSurfacePollTarget.Process {
        .init(bundleID: "com.apple.dt.Xcode", pid: 42)
    }

    /// THE FIRST SPOKEN TURN. Mary's overlay is frontmost; Xcode is still
    /// the active coding workspace. The poll must sample Xcode, not skip.
    func testMaryFrontmostSamplesARunningCodeSurface() {
        let hit = CodeSurfacePollTarget.resolve(
            frontmostBundleID: "nyc.rao.mary",
            maryBundleID: "nyc.rao.mary",
            registrations: [xcodeSurface],
            running: [xcodeProcess],
            preferredApplicationIDs: [])
        XCTAssertEqual(hit?.registration.applicationID, "xcode")
        XCTAssertEqual(hit?.pid, 42)
        XCTAssertEqual(hit?.isFrontmost, false)
    }

    /// A REAL DESTINATION IN FRONT is not this case. Safari leading would
    /// steal unled turns if a background Xcode filled `hasCoding`.
    func testAForeignFrontmostDoesNotPullABackgroundEditor() {
        let hit = CodeSurfacePollTarget.resolve(
            frontmostBundleID: "com.apple.Safari",
            maryBundleID: "nyc.rao.mary",
            registrations: [xcodeSurface],
            running: [xcodeProcess],
            preferredApplicationIDs: ["xcode"])
        XCTAssertNil(hit)
    }

    func testAFrontmostEditorWinsOverAStandingPreference() {
        let hit = CodeSurfacePollTarget.resolve(
            frontmostBundleID: "com.apple.dt.Xcode",
            maryBundleID: "nyc.rao.mary",
            registrations: [xcodeSurface, vscodeSurface],
            running: [
                xcodeProcess,
                .init(bundleID: "com.microsoft.VSCode", pid: 99),
            ],
            preferredApplicationIDs: ["vscode"])
        XCTAssertEqual(hit?.registration.applicationID, "xcode")
        XCTAssertEqual(hit?.isFrontmost, true)
    }

    func testTheStandingCaretBeatsAnotherRunningEditor() {
        let hit = CodeSurfacePollTarget.resolve(
            frontmostBundleID: "nyc.rao.mary",
            maryBundleID: "nyc.rao.mary",
            registrations: [xcodeSurface, vscodeSurface],
            running: [
                xcodeProcess,
                .init(bundleID: "com.microsoft.VSCode", pid: 99),
            ],
            preferredApplicationIDs: ["vscode"])
        XCTAssertEqual(hit?.registration.applicationID, "vscode")
        XCTAssertEqual(hit?.pid, 99)
        XCTAssertEqual(hit?.isFrontmost, false)
    }

    func testSystemChromeIsAsTransparentAsMary() {
        XCTAssertTrue(WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: "com.apple.dock", maryBundleID: "nyc.rao.mary"))
        XCTAssertTrue(WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: nil, maryBundleID: "nyc.rao.mary"))
        XCTAssertFalse(WorkspaceFocusTracker.isWorkspaceTransparent(
            bundleID: "com.apple.Safari", maryBundleID: "nyc.rao.mary"))
        let hit = CodeSurfacePollTarget.resolve(
            frontmostBundleID: "com.apple.dock",
            maryBundleID: "nyc.rao.mary",
            registrations: [xcodeSurface],
            running: [xcodeProcess],
            preferredApplicationIDs: [])
        XCTAssertEqual(hit?.registration.applicationID, "xcode")
        XCTAssertEqual(hit?.isFrontmost, false)
    }
}
