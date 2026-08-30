//
//  DeterministicWindowVerbTests.swift
//  MaryBrainTests
//
//  WHAT: When a window turn may skip the model — the gate is deliberately narrow.
//  OUT:  Deterministic window verb
//  PIN:  A false positive silently drops the rest of a compound request
//

import Foundation
import Testing
@testable import MaryBrain

@Suite struct DeterministicWindowVerbTests {

    // MARK: - What it takes

    @Test func listingAnApplicationsWindowsQualifies() {
        #expect(MaryBrain.deterministicWindowVerb("list the TextEdit windows")
            == "list_app_windows")
    }

    @Test func raisingEveryWindowQualifies() {
        #expect(MaryBrain.deterministicWindowVerb("bring all the TextEdit windows forward")
            == "bring_all_windows_forward")
    }

    // MARK: - What it refuses, and why

    /// THE ONE THAT MUST NEVER TAKE THIS PATH. It needs a window title, and
    /// nothing at this seam can resolve one; a raise that guesses lands on the
    /// wrong document.
    @Test func raisingOneNamedWindowKeepsItsModelRound() {
        #expect(MaryBrain.deterministicWindowVerb("bring Untitled 47 forward") == nil)
        #expect(MaryBrain.deterministicWindowVerb("bring the Notes window forward") == nil)
    }

    /// A LIVE CLASSIFIER BUG THIS PATH MUST NOT AMPLIFY.
    ///
    /// `WindowManagementTurnClassifier` reads the token "list" anywhere in the
    /// utterance as the verb, so "bring the Shopping List window forward" —
    /// where "List" is part of the WINDOW'S TITLE — is classified as
    /// `list_app_windows`. That is survivable while the classifier is only a
    /// hint: the model still calls `bring_window_forward` and the user gets
    /// their window. It would not be survivable on a path that executes the
    /// verdict and returns.
    ///
    /// This pins the refusal, not the classifier. If the classifier is fixed
    /// the refusal stays correct — a sentence carrying both readings is one
    /// the model should settle either way.
    @Test func aTitleContainingTheWordListDoesNotBecomeAListing() {
        #expect(WindowManagementTurnClassifier.classify(
            utterance: "bring the Shopping List window forward").invocationName
            == "list_app_windows")
        #expect(MaryBrain.deterministicWindowVerb(
            "bring the Shopping List window forward") == nil)
    }

    /// This path answers the whole turn and returns. A compound request would
    /// have its second half silently dropped.
    @Test func aCompoundRequestKeepsItsLane() {
        for utterance in [
            "list the TextEdit windows and read me the first one",
            "bring all the Pages windows forward then tighten the intro",
            "list the TextEdit windows, then close them",
            "bring all the windows forward; I want to see them",
            "list the TextEdit windows also open Safari",
        ] {
            #expect(
                MaryBrain.deterministicWindowVerb(utterance) == nil,
                "\(utterance) should not shortcut")
        }
    }

    @Test func aLongSentenceKeepsItsLane() {
        #expect(MaryBrain.deterministicWindowVerb(
            "could you please go ahead and list every single one of the TextEdit"
            + " windows for me right now") == nil)
    }

    @Test func aQuestionKeepsItsLane() {
        #expect(MaryBrain.deterministicWindowVerb(
            "how many TextEdit windows are open?") == nil)
    }

    @Test func aTurnAboutSomethingElseEntirelyIsNotAWindowVerb() {
        for utterance in [
            "tighten the intro",
            "what time is it",
            "make it full screen",
            "stop",
            "",
            "   ",
        ] {
            #expect(
                MaryBrain.deterministicWindowVerb(utterance) == nil,
                "\(utterance) should not shortcut")
        }
    }

    /// Asking for a script is asking for the model, not for a shortcut past it.
    @Test func anExplicitScriptRequestKeepsItsLane() {
        #expect(MaryBrain.deterministicWindowVerb(
            "run applescript to list the TextEdit windows") == nil)
    }

    /// The verdict is the classifier's, not a second copy of its vocabulary.
    /// Where this path acts at all, it acts on exactly what the classifier
    /// said — it may only ever refuse, never substitute a different verb.
    @Test func theVerdictAgreesWithTheClassifier() {
        for utterance in [
            "list the TextEdit windows",
            "bring all the TextEdit windows forward",
        ] {
            let classified = WindowManagementTurnClassifier
                .classify(utterance: utterance).invocationName
            #expect(MaryBrain.deterministicWindowVerb(utterance) == classified)
        }
    }
}
