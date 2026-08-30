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

    func testTheProseCursorObserverIsInTheShippedRoster() {
        XCTAssertTrue(
            observers.contains { $0.id == ProseSurfaceObserver.shared.id },
            "co-writing needs pair eyes, the same catalog ungating as code")
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
}
