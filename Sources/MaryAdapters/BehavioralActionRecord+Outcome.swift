//
//  BehavioralActionRecord+Outcome.swift
//  MaryAdapters
//
//  THE ONE PLACE A SETTLED SKILL BECOMES A RECORD.
//
//  Every executed action in Mary — dispatched by the model, pressed
//  deterministically by a lane, replayed after a confirmation — arrives here
//  as a `SkillOutcome` and leaves as a `BehavioralActionRecord`. That is the
//  whole reason this file is one function: the record is simultaneously the
//  dataset row, the transcript chip, and the execution-log entry, and the
//  moment two of those are composed in two places they start disagreeing about
//  what happened.
//
//  WHICH REFERENCE WINS, and why the order matters. `outcome.skillReference`
//  comes first because a confirmation replay carries the reference FROZEN at
//  park time — the binding the user actually approved, which may not be the
//  one the roster would choose now that focus has moved. The caller's
//  reference is the fallback for everything else. A snapshot reference taken
//  at composition time is never correct here and is not offered.
//
//  THE ADAPTER TRAIL IS NEVER LEFT BLANK. An outcome's own trail is the
//  FULFILLMENT CHAIN, and it is worth stating only when it differs from the
//  binding — the prose writer that falls back to keystrokes returns
//  `["prose-surface", "typer"]`, and no other value could be derived. When an
//  adapter says nothing, the turn-accurate reference already names the adapter
//  that ran, so the record takes it from there rather than shipping a dataset
//  row with a hole in it. This was found by the behavior probe: `list_documents`
//  returned a bare success and its row could not say who answered it, while the
//  `read_document` beside it could — the same act, described two ways,
//  depending on whether an author remembered.
//
//  IT LIVES IN MaryAdapters, not MaryBrain, because `SkillOutcome` does. The
//  layer that DEFINES an outcome is the layer that can say what the outcome
//  means, and putting the mapping a layer up would let the two drift.
//

import Foundation
import MaryFoundation

public extension BehavioralActionRecord {

    /// Compose the record for one settled dispatch.
    ///
    /// - Parameters:
    ///   - intention: the invocation name the model (or the lane) called.
    ///   - argumentsJSON: canonical, sorted-keys — the same bytes that went to
    ///     the binding, so a replay of the dataset is a replay of the act.
    ///   - reference: the TURN-ACCURATE binding reference, used unless the
    ///     outcome carries its own.
    ///   - runID: the model-wire invocation id. It is the record's id too:
    ///     one call, one record, one thing to correlate on.
    ///   - startedAt: when the dispatch began. Passed rather than taken here
    ///     because a duration measured from the moment we got round to
    ///     describing the act is not a duration of the act.
    init(
        outcome: SkillOutcome,
        intention: String,
        argumentsJSON: String,
        reference: AbilitySkillReference,
        runID: String,
        confirmationID: UUID? = nil,
        startedAt: Date,
        finishedAt: Date = Date()
    ) {
        let skill = outcome.skillReference ?? reference
        self.init(
            id: runID,
            action: BehavioralAction(
                intention: intention,
                argumentsJSON: argumentsJSON,
                skill: skill,
                target: outcome.target,
                adapters: outcome.adapterTrail.isEmpty
                    ? [skill.adapterID].compactMap(\.self)
                    : outcome.adapterTrail),
            disposition: BehavioralDisposition(outcome.status),
            summary: outcome.summary,
            foundNothing: outcome.foundNothing,
            // UNDOABLE MEANS "THIS CHANGED SOMETHING", not "Mary has an undo
            // for it". A read that found nothing changed nothing; anything
            // that ran and was not a read did.
            undoable: outcome.status == .succeeded && outcome.archivePolicy != .none,
            containerKey: outcome.passageHandle,
            confirmationID: confirmationID,
            startedAt: startedAt,
            finishedAt: finishedAt)
    }
}
