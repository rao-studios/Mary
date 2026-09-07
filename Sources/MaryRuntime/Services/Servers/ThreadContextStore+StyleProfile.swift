//
//  ThreadContextStore+StyleProfile.swift
//  MaryRuntime
//
//  WHAT: Style-profile documents in Thread.
//  IN:   StyleEvidenceStore tenets
//  OUT:  ThreadDirectClient
//

import MaryBrain
import MaryThread
import MaryFoundation
import Foundation

extension ThreadContextStore {

    // MARK: - Style profile

    /// Persist the profile as one document in the same envelope the export path uses.
    func depositStyleProfile(
        _ tenets: [StyleTenet],
        vetoedTenetKeys: [String] = [],
        applications: [String] = [],
        subject: String,
        at now: Date
    ) async {
        // Empty profile is deposited — that is how a forget becomes durable.
        guard let owner = await session.userID else { return }
        let profile = StyleProfile(
            profile: .init(
                subject: subject,
                version: SemanticVersion("1.0.0"),
                publisher: NSFullUserName(),
                summary: "How this person does \(subject) work.",
                createdAt: now,
                updatedAt: now),
            tenets: tenets,
            vetoedTenetKeys: vetoedTenetKeys)
        guard let data = try? StyleProfileCodec.encoded(profile),
              let content = String(data: data, encoding: .utf8) else { return }

        // Subject is the ability; applications are bindings. Every relation endpoint is an entity.
        var entities = [ThreadEntityIn(name: subject, kind: "ability")]
        var relationships: [ThreadRelationIn] = []
        for application in applications {
            entities.append(ThreadEntityIn(name: application, kind: "app"))
            relationships.append(ThreadRelationIn(
                subject: subject, predicate: "applies to", object: application))
        }

        let destination = ThreadMemoryTopology.styleGroup(ownerID: owner)
        let item = DepositItem(
            documentID: ThreadMemoryTopology.styleProfileDocumentID(
                subject: subject, ownerID: owner),
            texts: [content],
            tags: ["mary", "style-profile", subject],
            name: "\(subject) style profile",
            metadata: Data(),
            entities: entities,
            relationships: relationships)
        _ = try? await client.deposit(
            [item], ownerID: owner,
            groupID: destination.id, groupLabel: destination.label,
            scope: ThreadLane.personal.rawValue)
    }

    /// Restore the profile. A profile this build cannot read is refused by the
    /// codec rather than half-applied.
    func loadStyleProfile(
        subject: String
    ) async -> (tenets: [StyleTenet], vetoedTenetKeys: [String]) {
        guard let owner = await session.userID else { return ([], []) }
        let id = ThreadMemoryTopology.styleProfileDocumentID(subject: subject, ownerID: owner)
        guard let documents = try? await client.documents(ids: [id], ownerID: owner),
              let content = documents.first?.content,
              let profile = try? StyleProfileCodec.decode(
                  Data(content.utf8), verifyIntegrity: false)
        else { return ([], []) }
        return (profile.tenets, profile.vetoedTenetKeys ?? [])
    }

    /// The retrievable body. Structure, declaration headers, the author's own
    /// doc comment, and the generated précis and labels — never a body.
    static func unitDocument(_ unit: IndexedUnit) -> String {
        var lines = [
            "Code unit: \(unit.relativePath)",
            "Project: \(unit.projectName)",
        ]
        if !unit.declaredTypes.isEmpty {
            lines.append("Declares: \(unit.declaredTypes.joined(separator: ", "))")
        }
        let inherited = unit.relations
            .filter { $0.predicate == .inheritsFrom }
            .map { "\($0.subject) → \($0.object)" }
        if !inherited.isEmpty {
            lines.append("Inherits: \(inherited.joined(separator: ", "))")
        }
        let held = unit.relations.filter { $0.predicate == .holds }.map(\.object)
        if !held.isEmpty {
            lines.append("Holds: \(held.joined(separator: ", "))")
        }
        if let doc = unit.doc, !doc.isEmpty {
            lines.append("About: \(doc)")
        }
        if let annotation = unit.annotation, !annotation.precis.isEmpty {
            lines.append("Summary: \(annotation.precis)")
        }
        if let labels = unit.annotation?.labels, !labels.isEmpty {
            // The line that makes a code neighbourhood reachable from another
            // domain — it is what embeds, so it has to be prose in the body.
            lines.append("Concepts: \(labels.joined(separator: ", "))")
        }
        if !unit.apiHeaders.isEmpty {
            lines.append("API:")
            lines.append(contentsOf: unit.apiHeaders.map { "  \($0)" })
        }
        if !unit.neighbours.isEmpty {
            lines.append("Related: \(unit.neighbours.joined(separator: ", "))")
        }
        if let discipline = unit.discipline {
            lines.append("Discipline: \(discipline.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    static func unitMetadata(_ unit: IndexedUnit) -> Data {
        var fields: [String: Any] = [
            "kind": "code_unit",
            "application": unit.subject.app ?? "",
            "project": unit.projectName,
            "relative_path": unit.relativePath,
            "content_hash": unit.contentHash,
            "labels": (unit.annotation?.labels ?? []).sorted(),
            "captured_at": ISO8601DateFormatter().string(from: unit.capturedAt),
        ]
        if let discipline = unit.discipline {
            fields["ability_id"] = discipline.rawValue
            fields["paradigm"] = AbilityParadigm.discipline.rawValue
        }
        return (try? JSONSerialization.data(
            withJSONObject: fields, options: [.sortedKeys])) ?? Data()
    }

    /// Entity set derived from relations — Thread drops endpoints that do not resolve.
    static func unitComposition(
        _ unit: IndexedUnit
    ) -> (entities: [ThreadEntityIn], relationships: [ThreadRelationIn]) {
        var relationships = unit.relations.map {
            ThreadRelationIn(
                subject: $0.subject, predicate: $0.predicate.rawValue, object: $0.object)
        }
        for label in unit.annotation?.labels ?? [] {
            relationships.append(ThreadRelationIn(
                subject: unit.relativePath,
                predicate: UnitRelationPredicate.expresses.rawValue,
                object: label))
        }
        if let discipline = unit.discipline {
            relationships.append(ThreadRelationIn(
                subject: unit.projectName,
                predicate: UnitRelationPredicate.practices.rawValue,
                object: discipline.rawValue))
        }

        // Kinds for the names we know about; anything else reached only as a
        // relation endpoint is a type, which is what an unresolved edge always
        // refers to here.
        var kinds: [String: String] = [
            unit.relativePath: "file",
            unit.projectName: "project",
        ]
        if let discipline = unit.discipline {
            kinds[discipline.rawValue] = "ability"
        }
        for type in unit.declaredTypes { kinds[type] = "type" }
        for label in unit.annotation?.labels ?? [] { kinds[label] = "concept" }

        var entityNames: [String] = []
        var seen = Set<String>()
        for name in [unit.relativePath, unit.projectName]
            + relationships.flatMap({ [$0.subject, $0.object] })
        where !name.isEmpty && seen.insert(name).inserted {
            entityNames.append(name)
        }
        let entities = entityNames.map {
            ThreadEntityIn(name: $0, kind: kinds[$0] ?? "type")
        }
        return (entities, relationships)
    }

    // Application-schema observer persist was not ported — packages declare, nothing to guess.

}
