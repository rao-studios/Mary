//
//  AwarenessObserverTests.swift
//  MaryPluginTests
//
//  WHAT: The standing brief — published for the followed place, merged beside
//        the caret window, retracted when there is nothing to stand on.
//  OUT:  AwarenessObserver / WorkspaceFocusArbiter
//  PIN:  This observer must never take a lead away from the place that holds
//        the document; it only adds bearings to whichever section wins.
//

import Foundation
import MaryAmbient
import MaryFoundation
import Testing
@testable import MaryPlugin

@Suite struct AwarenessObserverTests {

    private static let place = AmbientPlace.application("tests.editor")

    private func observer(following: Bool) -> (AwarenessObserver, AwarenessSupport) {
        let support = AwarenessSupport()
        if following {
            support.reconcile([
                AwarenessRegistration(
                    applicationID: "tests.editor",
                    bundleIdentifiers: ["com.example.testeditor"],
                    displayName: "Test Editor",
                    surface: .document(
                        corpus: PluginCorpusSchema(include: ["swift"], notation: "swift")),
                    hasCodeSurface: true,
                    hasProseSurface: false),
            ])
        }
        return (AwarenessObserver(support: support), support)
    }

    // MARK: - What it contributes

    /// The brief is the observer's WHOLE contribution: bearings, no body, and
    /// no one-line identity — the surface observer already owns that.
    @Test func theBriefIsTheWholeContribution() {
        let (observer, _) = observer(following: true)
        observer.adoptStandingBriefForTests(
            place: Self.place, brief: "Around what they are working on:\n- open — S.swift:6: x")
        #expect(observer.observedPlace == Self.place)
        #expect(observer.promptContribution()?.contains("S.swift:6") == true)
        #expect(observer.ambientLine == nil, "identity belongs to the surface observer")
        #expect(!observer.holdsWholeDocument)
    }

    /// OFF THE TURN'S REFRESH BUDGET, on purpose: the 1 s window is shared by
    /// every sensing observer, and a walk over a project has no business in it.
    @Test func itIsNotOnThePerTurnRefreshBudget() {
        let (observer, _) = observer(following: true)
        #expect(observer.ambientSenses.isEmpty)
    }

    /// Nothing standing is nothing said — so it never enters the arbitration
    /// empty and takes a lead from a place with real work in it.
    @Test func withNothingStandingItSaysNothing() {
        let (observer, _) = observer(following: true)
        #expect(observer.observedPlace == nil)
        #expect(observer.promptContribution() == nil)
    }

    /// Nothing asked to be followed: the poll returns without reading anything.
    @Test func withNothingFollowedThePollDoesNotSettle() {
        let (observer, _) = observer(following: false)
        observer.pollOnce()
        #expect(observer.observedPlace == nil)
        #expect(observer.promptContribution() == nil)
    }

    @Test func deactivatingRetractsTheBrief() async {
        let (observer, _) = observer(following: true)
        observer.adoptStandingBriefForTests(place: Self.place, brief: "bearings")
        await observer.deactivate()
        #expect(observer.observedPlace == nil)
        #expect(observer.promptContribution() == nil)
    }
}
