//
//  ThreadContextStore.swift
//  MaryRuntime
//
//  WHAT: Archives completed actions and application knowledge into Thread.
//  OUT:  ThreadDirectClient. Siblings: +Addressing, +AbilityProjection,
//        +BehavioralEpisode, +StyleProfile, +UnitIndex.
//  PIN:  Ability Thread is BehavioralEpisode, not a skill receipt.
//

import MaryBrain
import MaryThread
import Foundation

package actor ThreadContextStore: ContextDepositing {

    struct ApplicationSchemaManifest: Codable {
    }

    var client: ThreadDirectClient
    let session: SewnSession
    var applicationProfiles: [String: ApplicationProfile] = [:]
    /// Application that produced a project's units — manifest group matches theirs.
    var unitManifestOwners: [String: String] = [:]
    /// Per-project catalogue of indexed units + revision. Relaunch resumes.
    var unitManifests: [String: UnitIndexManifest] = [:]
    /// Clamp so one giant Skill result is not a bloated thread document.
    let summaryLimit = 2000

    init(session: SewnSession, host: String = "127.0.0.1", port: Int = 9090) {
        self.session = session
        self.client = ThreadDirectClient(host: host, port: port)
    }

    package func configure(host: String = "127.0.0.1", port: Int) {
        client = ThreadDirectClient(host: host, port: port)
    }

    package func depositSkillResult(
        reference: AbilitySkillReference,
        skillName: String,
        argumentsJSON: String,
        summary: String,
        userText: String,
        subject: DepositSubject,
        applicationID: String?,
        policy: ArchivePolicy,
        succeeded: Bool,
        projectionPlan: AbilityThreadProjectionPlan?
    ) async {
        // Ability Thread is BehavioralEpisode, not a skill receipt. Dumps ride BehavioralOutput.
        return
    }

}
