// Archives completed actions and application knowledge into Totem.

import MaryBrain
import MaryTotem
import Foundation

package actor TotemContextStore: ContextDepositing {

    struct ApplicationSchemaManifest: Codable {
    }

    var client: TotemDirectClient
    let session: SeerSession
    var applicationProfiles: [String: ApplicationProfile] = [:]
    /// Which application produced a project's units, so the manifest lands in
    /// the SAME Totem group they did. This was hardcoded to Xcode's owner,
    /// which filed a Scrivener manuscript's index under the code editor.
    var unitManifestOwners: [String: String] = [:]
    /// The per-project catalogue of what has been indexed and at which
    /// revision, so a relaunch resumes instead of re-reading every file.
    var unitManifests: [String: UnitIndexManifest] = [:]
    /// Summaries are clamped so one giant Skill result (a whole file read)
    /// doesn't become a bloated totem document.
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
        // Ability Totem is the sealed BehavioralEpisode, not a skill receipt.
        // Machine-local adapter dumps used to land as mary-skill-* in Personal;
        // those actions already ride BehavioralOutput.
        return
    }

}
