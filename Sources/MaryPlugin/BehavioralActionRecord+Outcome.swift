//
//  BehavioralActionRecord+Outcome.swift
//  MaryPlugin
//
//  WHAT: One settled SkillOutcome → BehavioralActionRecord.
//  IN:   Ability runtime (dispatch / confirmation replay)
//  OUT:  dataset row / transcript chip / execution log
//  PIN:  Lives beside SkillOutcome. outcome.skillReference wins (frozen at
//        park); caller reference is fallback. Adapter trail never left blank.
//

import Foundation
import MaryFoundation

public extension BehavioralActionRecord {

    /// Compose the record for one settled dispatch.
    /// PIN: `outcome.skillReference` wins; caller `reference` is fallback.
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
            // PIN: undoable = something changed, not "Mary has an undo".
            undoable: outcome.status == .succeeded && outcome.archivePolicy != .none,
            containerKey: outcome.passageHandle,
            confirmationID: confirmationID,
            startedAt: startedAt,
            finishedAt: finishedAt)
    }
}
