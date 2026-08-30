//
//  TotemContextStore.swift
//  MaryRuntime
//
//  WHAT: Archives completed actions and application knowledge into Totem.
//  OUT:  TotemDirectClient. Siblings: +Addressing, +AbilityProjection,
//        +BehavioralEpisode, +StyleProfile, +UnitIndex.
//  PIN:  Ability Totem is BehavioralEpisode, not a skill receipt.
//

import MaryBrain
import MaryTotem
import Foundation

package actor TotemContextStore: ContextDepositing {

    struct ApplicationSchemaManifest: Codable {
    }

    var client: TotemDirectClient
    let session: SeerSession
    var applicationProfiles: [String: ApplicationProfile] = [:]
    /// Application that produced a project's units — manifest group matches theirs.
    var unitManifestOwners: [String: String] = [:]
    /// Per-project catalogue of indexed units + revision. Relaunch resumes.
    var unitManifests: [String: UnitIndexManifest] = [:]
    /// Clamp so one giant Skill result is not a bloated totem document.
    let summaryLimit = 2000

    init(session: SeerSession, host: String = "127.0.0.1", port: Int = 9090) {
        self.session = session
        self.client = TotemDirectClient(host: host, port: port)
    }

    package func configure(host: String = "127.0.0.1", port: Int) {
        client = TotemDirectClient(host: host, port: port)
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
        projectionPlan: AbilityTotemProjectionPlan?
    ) async {
        // Ability Totem is BehavioralEpisode, not a skill receipt. Dumps ride BehavioralOutput.
        return
    }

}
