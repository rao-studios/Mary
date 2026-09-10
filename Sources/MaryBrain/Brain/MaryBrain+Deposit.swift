//
//  MaryBrain+Deposit.swift
//  MaryBrain
//
//  WHAT: Archive a dispatched Skill outcome into Thread.
//  IN:   depositor + depositSubjectProvider + ambient
//  OUT:  ContextDepositing
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
        // A local binding's archive policy remains a hard floor.
        if deferred || policy == .none { return }
        let projectionPlan: AbilityThreadProjectionPlan?
        if reference.source == .package {
            projectionPlan = dispatcher?.abilitySnapshot.threadProjectionPlan(for: reference)
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
        if skillPlace?.placeClass == .dataSource {
            subject = .unfocused
        }
        // Dynamic applications deliberately do not become closed `AmbientAttention` enum cases.
        let applicationID = reference.provider?.applicationID
            ?? (skillPlace?.placeClass == .dataSource
                ? skillPlace?.application
                : subject.app)
        let route = world.store.route()
        // APPLICATION-USE LEARNING IS NOT IN THIS CUT.
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
