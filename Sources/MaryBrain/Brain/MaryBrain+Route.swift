//
//  MaryBrain+Route.swift
//  MaryBrain
//
//  THE TAXONOMY SEAM. This file exists so the AmbientPlace migration lands
//  in one small file: the route-adjacent revision spine moved here from
//  MaryBrain.swift — `locateTarget(for:worldHint:)`, `revisionReport`,
//  — the methods that turn an utterance's route
//  into a located passage or canvas layer. (`runTurnBody`'s in-function
//  route resolution stays with the turn loop; a function is never split.)
//
//  Moved verbatim; no behavior change. Depends on the internal-for-split
//  promotions of `dispatcher`, `recentApplicationReferent`,
//  `preReadBudgetNanoseconds`, and `withNanosecondBudget` in the core file;
//  treat those as private.
//

import MaryFoundation
import MaryVoice
import Foundation
import os

extension MaryBrain {

    // MARK: - The revision spine, shared by both turn shapes

    /// LOCATE-FIRST, factored — the one place a revision's target is found.
    ///
    /// Nil is the common answer and costs exactly nothing: no edit intent, no
    /// dispatcher, no leading world, a world that composes but cannot revise,
    /// nothing open, nothing found. No gate fires and the turn runs precisely
    /// as it did before any of this existed.
    ///
    /// INSIDE THE PRE-READ'S OWN LATENCY BUDGET, not a new one. The locate is
    /// the same shape of work the read is (one round trip into whatever leads
    /// the turn), and a revision turn is usually a SILENT action turn — the
    /// user is watching for the document to change, so a wedged Pages must buy
    /// at most the same 2.5 seconds it may buy the voice.
    ///
    /// NO LEDGER ROW, DELIBERATELY, and this is a gap rather than an oversight.
    /// Every existing `ReadRoute` describes where a read's TEXT ended up, and
    /// `.prefetched` says "pre-read → voice" — which is false about a locate
    /// twice over: nothing was read for the voice, and the passage goes to the
    /// Skill execution lane's prompt. The ledger is the one instrument in this process
    /// that is not allowed to lie about delivery, so it says nothing rather
    /// than something untrue. A `.locatedForEdit` row belongs in
    /// `ReadDeliveryLedger`.
    // internal for file split — treat as private
    func locateTarget(
        for intent: EditIntent?, worldHint: AmbientWorld? = nil
    ) async -> LocatedPassage? {
        guard let intent, let dispatcher else { return nil }
        return await withNanosecondBudget(Self.preReadBudgetNanoseconds) {
            await dispatcher.locatePassage(intent, worldHint: worldHint)
        }
    }

    /// G4, factored — the deterministic sentence a revision owes about itself,
    /// already spaced to follow whatever prose came before it, and already
    /// yielded. Nil means THIS TURN OWES NONE, which is almost every turn.
    ///
    /// Shared by both turn shapes because both can perform a revision and both
    /// owe the same sentence for it; what differs is only where the returned
    /// text accumulates (`spokenText` in one, the streamed reply in the other),
    /// which is why this hands the sentence back rather than writing it
    /// anywhere itself.
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
