//
//  TotemContextStore+Addressing.swift
//

import MaryBrain
import MaryTotem
import MaryFoundation
import Foundation

extension TotemContextStore {

    // MARK: - Addressing (pure, unit-tested — no server required)

    /// The group a deposit belongs to. No owner-wide bag: without a project
    /// or document scope there is nowhere to file.
    package static func destination(
        subject: DepositSubject, ownerID: String
    ) -> (id: String, label: String)? {
        guard let scoped = subject.groupID(ownerID: ownerID) else { return nil }
        return (scoped, subject.groupLabel)
    }

    struct ProjectionDestination {
        package var lane: TotemLane
        package var id: String
        package var label: String
    }

    /// Durable projections always file to Ability Totem. Destinations come from
    /// the executing Ability and, for application expertise, the disciplines
    /// it extends. Personal style is a different deposit path.
    static func projectionDestinations(
        projection: ResolvedTotemProjection,
        subject _: DepositSubject,
        routingSubject _: DepositSubject,
        applicationID _: String?,
        targets: [AbilityTotemTarget],
        ownerID: String
    ) -> [ProjectionDestination] {
        guard projection.permitsDurableStorage else { return [] }

        var destinations: [ProjectionDestination] = []
        for target in targets {
            let ability = TotemMemoryTopology.abilityGroup(
                target: target, ownerID: ownerID)
            destinations.append(.init(
                lane: .ability, id: ability.id, label: ability.label))
        }

        var seen = Set<String>()
        return destinations.filter { seen.insert($0.id).inserted }
    }

    static func projectedSubject(
        _ subject: DepositSubject,
        fields: Set<String>,
        excluded: Set<String>
    ) -> DepositSubject {
        func includes(_ field: String) -> Bool {
            fields.contains(field) && !excluded.contains(field)
        }
        let targetScope = includes("targetScope")
        return DepositSubject(
            app: targetScope || includes("applicationID") ? subject.app : nil,
            documentIdentity: targetScope || includes("documentID")
                ? subject.documentIdentity : nil,
            projectIdentity: targetScope || includes("projectID") || includes("project")
                ? subject.projectIdentity : nil,
            contentKind: subject.contentKind,
            capturedAt: subject.capturedAt)
    }

    static func projectedComposition(
        reference: AbilitySkillReference,
        fields: [ProjectedField],
        subject: DepositSubject,
        applicationID: String?,
        projection: ResolvedTotemProjection
    ) -> ContextEntityComposer.Composition {
        let included = Set(fields.map(\.name))
        let raw = ContextEntityComposer.compose(
            reference: reference,
            argumentsJSON: "{}",
            userText: "",
            userName: "",
            projectRoot: subject.projectIdentity,
            activeFilePath: subject.contentKind == .file
                ? subject.documentIdentity : nil,
            app: included.contains("applicationID") || included.contains("targetScope")
                ? applicationID ?? subject.app : nil,
            document: subject.documentIdentity)
        var allowedKinds = Set<String>()
        if included.contains("packageID") || included.contains("packageVersion") {
            allowedKinds.insert("ability-package")
        }
        if included.contains("abilityID") { allowedKinds.insert("ability") }
        if included.contains("skillID") { allowedKinds.insert("skill") }
        if included.contains("applicationID") || included.contains("targetScope") {
            allowedKinds.insert("app")
        }
        if !included.isDisjoint(with: ["project", "projectID", "targetScope"]) {
            allowedKinds.insert("project")
        }
        if included.contains("documentID") || included.contains("targetScope") {
            allowedKinds.formUnion(["document", "file"])
        }

        var composition = ContextEntityComposer.Composition(
            entities: raw.entities.filter { allowedKinds.contains($0.kind) },
            relationships: [])
        var names = Set(composition.entities.map(\.name))
        composition.relationships = raw.relationships.filter {
            names.contains($0.subject) && names.contains($0.object)
        }

        let values = Dictionary(
            fields.map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first })
        let projectName = values["project"] ?? values["projectID"]
            ?? subject.projectIdentity.map { ($0 as NSString).lastPathComponent }
        if let projectName, !projectName.isEmpty, !names.contains(projectName) {
            composition.entities.append(TotemEntityIn(name: projectName, kind: "project"))
            names.insert(projectName)
        }
        let knowledge: (value: String, predicate: String)? = {
            if let decision = values["decision"] {
                return (decision, "records decision")
            }
            if let note = values["text"] {
                return (note, "records project knowledge")
            }
            return nil
        }()
        if projection.purpose == .content,
           let knowledge,
           !knowledge.value.isEmpty {
            let concept = clamp(knowledge.value, limit: 300)
            if !names.contains(concept) {
                composition.entities.append(TotemEntityIn(name: concept, kind: "concept"))
                names.insert(concept)
            }
            if let projectName, names.contains(projectName) {
                composition.relationships.append(TotemRelationIn(
                    subject: projectName,
                    predicate: knowledge.predicate,
                    object: concept))
            }
        }
        return composition
    }

    /// Deterministic for a state snapshot with a known document; a fresh uuid
    /// otherwise. The `??` is load-bearing: a `.stateSnapshot` with NO
    /// document identity has nothing to key on, and inventing a key would
    /// make two unrelated deposits silently overwrite each other — worse than
    /// the accumulation this replaces.
    package static func documentID(
        subject: DepositSubject,
        policy: ArchivePolicy,
        ownerID: String,
        lane: TotemLane? = nil,
        projectionID: ProjectionID? = nil
    ) -> String {
        let stable = policy == .stateSnapshot
            ? subject.stateDocumentID(ownerID: ownerID)
            : nil
        if let stable, let lane, let projectionID {
            return "\(stable)-\(lane.rawValue)-\(projectionID.rawValue)"
        }
        if let stable, let lane { return "\(stable)-\(lane.rawValue)" }
        return stable ?? "mary-skill-\(UUID().uuidString.lowercased())"
    }

    /// `DepositItem.metadata` was wired to the proto and never populated —
    /// a free channel, and the only place a deposit can say WHEN it was true
    /// and WHAT it was about. `PartitionHit` still carries no `createdAt`, so
    /// this is a record for later (and for the probe), not a live recency
    /// lever. Encoding failure yields empty Data: metadata must never be able
    /// to fail a deposit.
    package static func metadata(
        subject: DepositSubject,
        policy: ArchivePolicy,
        reference: AbilitySkillReference,
        bindingName: String,
        succeeded: Bool = true,
        projection: ResolvedTotemProjection? = nil,
        lane: TotemLane? = nil
    ) -> Data {
        var fields: [String: String] = [
            "captured_at": ISO8601DateFormatter().string(from: subject.capturedAt),
            "archive_policy": policy.rawValue,
            "package_id": reference.packageID.rawValue,
            "package_version": reference.packageVersion.rawValue,
            "ability_id": reference.abilityID.rawValue,
            "skill_id": reference.skillID.rawValue,
            "invocation_name": reference.invocationName,
            "binding_name": bindingName,
            "reference_source": reference.source.rawValue,
            "status": succeeded ? "succeeded" : "failed",
        ]
        if let projection {
            fields["projection_ids"] = projection.id.rawValue
            fields["projection_purpose"] = projection.purpose.rawValue
            fields["projection_persistence"] = projection.persistence.rawValue
            fields["projection_redacted"] = projection.redactContent ? "true" : "false"
            if let retention = projection.retentionSeconds {
                fields["projection_retention_seconds"] = String(retention)
            }
        }
        if let lane { fields["totem_lane"] = lane.rawValue }
        if let digest = reference.packageDigest { fields["package_digest"] = digest }
        if let adapter = reference.adapterID { fields["adapter_id"] = adapter.rawValue }
        if let app = subject.app { fields["app"] = app }
        if let document = subject.documentIdentity { fields["doc_identity"] = document }
        if let project = subject.projectIdentity { fields["project"] = project }
        fields["content_kind"] = subject.contentKind.rawValue
        return (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    static func applicationMetadata(_ profile: ApplicationProfile) -> Data {
        let fields: [String: Any] = [
            "kind": "application_knowledge",
            "application": profile.id,
            "abilities": profile.abilities.map(\.rawValue).sorted(),
            "skill_count": profile.skills.count,
        ]
        return (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

}
