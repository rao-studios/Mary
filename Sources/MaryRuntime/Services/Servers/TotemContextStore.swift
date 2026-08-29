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
        guard let owner = await session.userID else { return }

        if let projectionPlan {
            guard projectionPlan.matches(reference) else { return }
            let projections = Self.durableProjections(
                in: projectionPlan, succeeded: succeeded)
            for projection in projections {
                await depositProjectedResult(
                    reference: reference,
                    skillName: skillName,
                    argumentsJSON: argumentsJSON,
                    summary: summary,
                    userText: userText,
                    subject: subject,
                    applicationID: applicationID,
                    policy: policy,
                    succeeded: succeeded,
                    projection: projection,
                    targets: projectionPlan.abilityTargets,
                    ownerID: owner)
            }
            return
        }

        // Machine-local adapters have no portable package policy. Preserve
        // their explicit archive contract, but keep this path separate so it
        // can never accidentally widen a packaged projection.
        let composition = ContextEntityComposer.compose(
            reference: reference,
            argumentsJSON: argumentsJSON,
            userText: userText,
            userName: NSFullUserName(),
            projectRoot: subject.projectIdentity,
            activeFilePath: subject.contentKind == .file
                ? subject.documentIdentity : nil,
            app: applicationID ?? subject.app,
            document: subject.documentIdentity)
        let clamped = Self.clamp(summary, limit: summaryLimit)
        let local = Self.destination(subject: subject, ownerID: owner)
        let item = DepositItem(
            documentID: Self.documentID(
                subject: subject, policy: policy, ownerID: owner),
            texts: ["\(reference.displayLabel) — for: \(userText)\n\(clamped)"],
            tags: ["mary", "skill:\(reference.skillID.rawValue)"],
            name: "\(reference.displayLabel) result",
            metadata: Self.metadata(
                subject: subject,
                policy: policy,
                reference: reference,
                bindingName: skillName,
                succeeded: succeeded),
            entities: composition.entities,
            relationships: composition.relationships)
        _ = try? await client.deposit(
            [item], ownerID: owner, groupID: local.id, groupLabel: local.label)
    }

}
