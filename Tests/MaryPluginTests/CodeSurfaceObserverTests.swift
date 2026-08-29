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

    /// IT SPEAKS FOR NO PLACE AND CONTRIBUTES NO PROMPT TEXT. Both are
    /// deliberate and both are load-bearing: `WorkspaceFocusArbiter` weighs
    /// the observers that answer a place, and `CorpusObserver` already speaks
    /// for the same one — two observers voting for a lane is the same
    /// evidence counted twice, not more of it. The prompt text goes through
    /// the ambient store instead, where the budget is decided once.
    func testItIsInfrastructureRatherThanAVoiceInTheArbiter() {
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
}
