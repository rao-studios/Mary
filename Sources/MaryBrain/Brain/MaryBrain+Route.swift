//
//  MaryBrain+Route.swift
//  MaryBrain
//
//  WHAT: Revision spine — locateTarget / revisionReport from the route.
//  IN:   runTurnBody route + dispatcher
//  OUT:  LocatedArtifact / RevisionVeto
//  PIN:  runTurnBody's in-function route resolution stays in the turn loop.
//
import MaryFoundation
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - The revision spine, shared by both turn shapes

    /// LOCATE-FIRST, factored — the one place a revision's target is found.
    // internal for file split — treat as private
    func locateTarget(
        for intent: EditIntent?, worldHint: AmbientWorld? = nil
    ) async -> LocatedPassage? {
        guard let intent, let dispatcher else { return nil }
        return await withNanosecondBudget(Self.preReadBudgetNanoseconds) {
            await dispatcher.locatePassage(intent, worldHint: worldHint)
        }
    }

    /// G4, factored — the deterministic sentence a revision owes about itself, already spaced to follow whatever prose came before it, and already yielded.
    // internal for file split — treat as private
    func revisionReport(
        intent: EditIntent?,
        target: LocatedPassage?,
        writingTarget: AmbientWritingTarget? = nil,
        acceptedOffer: Bool = false,
        outcomes: [LaneOutcome],
        after spoken: String,
        continuation: AsyncThrowingStream<BrainEvent, Error>.Continuation
    ) -> String? {
        guard let report = EditReport.report(
            intent: intent, target: target,
            writingTarget: writingTarget,
            acceptedOffer: acceptedOffer,
            outcomes: outcomes) else { return nil }
        let sentence = spoken.isEmpty ? report.sentence : " \(report.sentence)"
        continuation.yield(.token(sentence))
        return sentence
    }

}
