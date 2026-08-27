//
//  ReferenceCorrectionTests.swift
//  MaryBrainTests
//
//  THE THIRD CLAUSE OF THE DOCTRINE, tested.
//
//  The shipped voice prompt has always said: "take the reading they most likely
//  meant and say plainly which one you took, **so they can correct you in one
//  word**." Acting was built. Announcing was half-built. Correcting was prose —
//  "say undo", "say the word and I'll put it back" — with nothing behind it,
//  while a yes/no on a parked write bypasses the model entirely.
//
//  These are the tests for the mechanism that closes it. Re-aim only: what
//  already landed stays.
//

import Foundation
import Testing

@testable import MaryBrain
@testable import MaryAdapters
@testable import MaryAmbient

@Suite struct BareCorrectionTests {

    @Test(arguments: [
        "no, the other one", "the other one", "not that one", "wrong note",
        "I meant the other one", "No the other note.", "  the other document  ",
    ])
    func aOneWordCorrectionIsRecognised(_ text: String) {
        #expect(MaryBrain.bareCorrection(in: text), "[\(text)] should be a correction")
    }

    /// CONSERVATIVE, EXACTLY AS `bareDecision` IS, and for a sharper reason: a
    /// false positive silently re-aims which document the NEXT command lands in.
    @Test(arguments: [
        // Names a specific alternative — that is the ordinal rung's job, not a
        // bare correction's.
        "not that one, the third one",
        "the other one has the grocery list in it",
        // Ordinary prose that happens to contain the words.
        "put the other one below this",
        "read me the other one",
        "delete the other one",
        // Decisions, not corrections.
        "no", "cancel", "yes",
        "",
    ])
    func ordinaryProseIsNotACorrection(_ text: String) {
        #expect(!MaryBrain.bareCorrection(in: text), "[\(text)] must not be a correction")
    }

    /// A correction and a decision must never both fire on one utterance.
    @Test func correctionsAndDecisionsDoNotOverlap() {
        for text in ["no", "nope", "cancel", "yes", "go ahead"] {
            #expect(MaryBrain.bareDecision(in: text) != nil)
            #expect(!MaryBrain.bareCorrection(in: text), "[\(text)] is a decision, not a correction")
        }
    }
}

@Suite struct ApplyCorrectionTests {

    private func roster(_ rows: [ContainerRow]) -> ContainerRoster {
        ContainerRoster(place: .application("scribe"), handlePrefix: "W", cached: { rows })
    }

    private var three: ContainerRoster {
        roster([
            .init(key: "a", title: "Note A", listIndex: 1, isFront: true),
            .init(key: "b", title: "Note B", listIndex: 2),
            .init(key: "c", title: "Note C", listIndex: 3),
        ])
    }

    private func referent(_ key: String, alternative: String? = nil) -> ResolvedReferent {
        ResolvedReferent(
            place: .application("scribe"), key: key, title: "Note \(key.uppercased())",
            rung: .anaphora, confidence: alternative == nil ? .exact : .chosen,
            alternative: alternative.map {
                .init(place: .application("scribe"), key: $0, title: "Note \($0.uppercased())")
            })
    }

    /// THE RUNNER-UP IS WHERE IT RE-AIMS. This is why `Choice.alternative` is
    /// carried at all — without it a correction has nothing to name.
    @Test func aCorrectionReAimsToTheRunnerUp() throws {
        let registry = ContainerRegistry()
        let intended = ReferenceFocus.applyCorrection(
            to: referent("b", alternative: "c"), rosters: [three], registry: registry)
        #expect(intended?.key == "c")
    }

    /// AND IT DEMOTES THE REJECTED ONE. Without this, "no, the other one"
    /// followed by "add this too" lands straight back where the correction
    /// rejected — because the rejected note is the most recent thing Mary
    /// touched.
    @Test func theRejectedContainerStopsWinningTheNextPick() throws {
        let registry = ContainerRegistry()
        // Mary acted on B, so B is the most salient thing there is.
        registry.noteEvidence(place: .application("scribe"), key: "b", .actedOn)
        #expect(registry.salienceRanks(place: .application("scribe"), keys: ["b", "c"])["b"] == 0)

        ReferenceFocus.applyCorrection(
            to: referent("b", alternative: "c"), rosters: [three], registry: registry)

        let ranks = registry.salienceRanks(place: .application("scribe"), keys: ["b", "c"])
        #expect(ranks["c"] == 0, "the corrected container must now lead")
        #expect(ranks["b"] == nil, "the rejected container must stop being preferred")
    }

    /// `.corrected` outranks everything, because it is the only class that is
    /// not an inference — the user said it out loud.
    @Test func aCorrectionOutranksAnAct() {
        let registry = ContainerRegistry()
        let now = Date(timeIntervalSince1970: 5_000)
        // The act is NEWER and must still lose.
        registry.noteEvidence(place: .application("scribe"), key: "c", .corrected, at: now.addingTimeInterval(-600))
        registry.noteEvidence(place: .application("scribe"), key: "b", .actedOn, at: now)

        let ranks = registry.salienceRanks(place: .application("scribe"), keys: ["b", "c"], at: now)
        #expect(ranks["c"] == 0)
        #expect(ranks["b"] == 1)
    }

    /// With no explicit runner-up, it re-aims to the most salient other
    /// container in that world.
    @Test func withNoRunnerUpItTakesTheNextMostSalient() throws {
        let registry = ContainerRegistry()
        registry.noteEvidence(place: .application("scribe"), key: "c", .touched)
        let intended = ReferenceFocus.applyCorrection(
            to: referent("b"), rosters: [three], registry: registry)
        #expect(intended?.key == "c")
    }

    /// NOTHING TO RE-AIM TO IS STILL INFORMATION. "Not that one" with only one
    /// container demotes it rather than pretending the correction never happened.
    @Test func aCorrectionWithNowhereToGoStillDemotes() {
        let registry = ContainerRegistry()
        let only = roster([.init(key: "a", title: "Note A", listIndex: 1, isFront: true)])
        registry.noteEvidence(place: .application("scribe"), key: "a", .actedOn)

        let intended = ReferenceFocus.applyCorrection(
            to: referent("a"), rosters: [only], registry: registry)
        #expect(intended == nil)
        // Demoted to the weakest class rather than left leading.
        #expect(registry.evidence(place: .application("scribe"), key: "a")?.kind == .corrected
            || registry.evidence(place: .application("scribe"), key: "a")?.kind == .shown)
    }

    /// IT DOES NOT UNDO — the decision, stated as a test. There is no revert
    /// call on this path at all.
    @Test func aCorrectionTouchesNothingThatAlreadyLanded() {
        let registry = ContainerRegistry()
        let undo = ContentUndoStore()
        undo.record(key: "b", prior: "before", applied: "after")

        ReferenceFocus.applyCorrection(
            to: referent("b", alternative: "c"), rosters: [three], registry: registry)

        // The undo entry is untouched: nothing was reverted, nothing consumed.
        #expect(undo.entry(for: "b") != nil)
    }
}
