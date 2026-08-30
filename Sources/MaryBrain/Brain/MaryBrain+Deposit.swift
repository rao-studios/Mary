//
//  MaryBrain+Deposit.swift
//  MaryBrain
//
//  The deposit seam, moved out of MaryBrain.swift: `archive(...)`, the
//  one place a dispatched Skill's outcome is folded into Totem context.
//
//  Moved verbatim; no behavior change. Depends on the internal-for-split
//  promotions of `depositor`, `depositSubjectProvider`, and `ambient` in
//  the core file; treat those as private.
//

import MaryVoice
import Foundation
import os

extension MaryBrain {

    // internal for file split — treat as private
    func archive(
        reference: AbilitySkillReference,
        skillName: String,
        argumentsJSON: String,
        summary: String,
        userText: String,
        succeeded: Bool, deferred: Bool, policy: ArchivePolicy
    ) {
        guard let depositor else { return }
        // A local binding's archive policy remains a hard floor. Packaged
        // Skills then pass through their own frozen projection: no projection
        // means no durable package data, and session-only projections stay in
        // the in-memory route ledger. Unpackaged machine-local adapters retain
        // their explicit local behavior until they join a portable Ability.
        if deferred || policy == .none { return }
        let projectionPlan: AbilityTotemProjectionPlan?
        if reference.source == .package {
            projectionPlan = dispatcher?.abilitySnapshot.totemProjectionPlan(for: reference)
                ?? .denied(for: reference)
            guard projectionPlan?.permitsDurableStorage == true else { return }
        } else {
            projectionPlan = nil
            guard dispatcher?.isReadOnly(skillName) != true else { return }
        }
        // Capture focus before the detached deposit can observe a later turn.
        var subject = depositSubjectProvider()
        // Data-source actions belong to their source, not the open document.
        let skillPlace = dispatcher?.place(ofSkill: skillName)
        if skillPlace?.worldClass == .dataSource {
            subject = .unfocused
        }
        // Dynamic applications deliberately do not become closed
        // `AmbientWorld` enum cases. Their frozen provider reference is the
        // stronger attribution source: a Design Skill realized by Sketch must
        // teach Sketch's Ability Totem even when ambient focus is generic
        // or has already changed before this detached deposit runs.
        let applicationID = reference.provider?.applicationID
            ?? (skillPlace?.worldClass == .dataSource
                ? skillPlace?.application
                : subject.app)
        let route = ambient.route()
        // APPLICATION-USE LEARNING IS NOT IN THIS CUT. A block here used to
        // compose the executed Ability, the turn's writing target and the
        // place's own facts into one observation, and hand it to the corpus
        // that learns which application serves which kind of work. That
        // corpus is deferred, and half of the pipeline — an observation with
        // nothing observing it — would be worse than neither half.
        _ = route
        Task.detached {
            await depositor.depositSkillResult(
                reference: reference,
                skillName: skillName,
                argumentsJSON: argumentsJSON,
                summary: summary, userText: userText,
                subject: subject, applicationID: applicationID, policy: policy,
                succeeded: succeeded, projectionPlan: projectionPlan)
        }
    }
}
