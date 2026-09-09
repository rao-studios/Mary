//
//  WindowManagementTurnClassifierTests.swift
//  MaryPluginTests
//
//  WHAT: The word-shape gate in front of the window skills.
//  OUT:  WindowManagementTurnClassifier.classify
//  PIN:  THE "OPEN" TRAP HAS ITS OWN TESTS. Two shipped fixtures are LIST
//        requests containing the word "open" ("Which note windows are open?",
//        "What windows do I have open?"). Any future edit that keys the
//        new-window shape on that word will break them here rather than in
//        somebody's session.
//

import Foundation
import Testing
@testable import MaryPlugin

@Suite struct WindowManagementTurnClassifierTests {

    private func classify(_ utterance: String) -> WindowManagementTurnIntent {
        WindowManagementTurnClassifier.classify(utterance: utterance)
    }

    // MARK: - Asking for a window that does not exist yet

    /// THE REPORTED CASE. Before this shape existed the sentence produced no
    /// invocation at all, and minted `macos-application-window` — the one
    /// target class `bring-application-forward` EXCLUDES — so the phrase
    /// actively disqualified the only skill that could have launched anything.
    @Test func openingANewWindowIsItsOwnOperation() {
        let intent = classify("Open a new textedit window")
        #expect(intent.invocationName == "open_new_window")
        #expect(intent.targetClasses.contains("window-operation.open-new"))
    }

    @Test func newnessIsRecognisedWithoutTheVerbOpen() {
        #expect(classify("Give me another window").invocationName == "open_new_window")
        #expect(classify("Start a fresh window").invocationName == "open_new_window")
    }

    // MARK: - The words that must NOT mean a new window

    /// Both are shipped route fixtures for `list_app_windows`, and both contain
    /// "open" as an ADJECTIVE. This is why the shape keys on newness.
    @Test func openAsAnAdjectiveStillLists() {
        #expect(classify("Which note windows are open?").invocationName
            == "list_app_windows")
        #expect(classify("What windows do I have open?").invocationName
            == "list_app_windows")
    }

    @Test func theExistingWindowVerbsAreUnchanged() {
        #expect(classify("Bring all my windows forward").invocationName
            == "bring_all_windows_forward")
        #expect(classify("Make this full screen").invocationName
            == "make_window_full_screen")
        #expect(classify("Exit full screen").invocationName == "exit_full_screen")
        #expect(classify("Restore that window").invocationName == "restore_window")
    }

    /// A titled window is only recognised inside a place that HAS documents —
    /// "Untitled 9" is a window title there and a bare noun anywhere else.
    /// Pre-existing behaviour, pinned here because the new-window shape sits
    /// directly above it in the same if-chain.
    @Test func aTitledWindowNeedsADocumentPlace() {
        let place = WindowManagementDocumentPlace(
            applicationID: "textedit", documentNoun: "note", isReferent: false)
        #expect(WindowManagementTurnClassifier.classify(
            utterance: "Bring Untitled 9 forward", documentPlace: place)
            .invocationName == "bring_window_forward")
        #expect(classify("Bring Untitled 9 forward").invocationName == nil)
    }

    /// A new-window shape must not fire on a sentence that is not about a
    /// window at all — "a new document" belongs to the writing discipline.
    @Test func newnessAloneIsNotAWindowRequest() {
        let intent = classify("Create a new document")
        #expect(!intent.targetsWindow)
        #expect(intent.invocationName == nil)
    }

    /// Full screen is decided before newness, and says so.
    @Test func fullScreenStillWinsOverNewness() {
        #expect(classify("Make this new window full screen").invocationName
            == "make_window_full_screen")
    }
}
