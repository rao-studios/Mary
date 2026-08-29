//
//  TotemContextStore+StyleProfile.swift
//

import MaryBrain
import MaryTotem
import MaryFoundation
import Foundation

extension TotemContextStore {

    // MARK: - Style profile

    /// Persist the whole profile as one canonical document.
    ///
    /// It is stored in the SAME portable envelope the export path uses, not a
    /// private encoding — so what survives a relaunch and what you could hand
    /// to someone else are the same bytes, and the format only has to be right
    /// once.
    func depositStyleProfile(
        _ tenets: [StyleTenet],
        vetoedTenetKeys: [String] = [],
        applications: [String] = [],
        subject: String,
        at now: Date
    ) async {
        // An EMPTY profile is deposited deliberately — it is how a forget
        // becomes durable. Skipping it left the old document standing, and the
        // next relaunch restored what the user had just erased.
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

        // THE STYLE GRAPH JOINS THE ABILITY GRAPH. `ability` is already a kind
        // in `TotemGraphPolicy.maryKinds` and `ability_id` already rides
        // every Skill deposit's metadata, so naming the Ability here is what
        // lets a design tenet and a design Skill receipt be the same subject
        // in the graph rather than two unrelated islands. Every relationship
        // endpoint ships as an entity — Totem drops relations whose endpoints
        // do not resolve.
        // THE SUBJECT IS THE ABILITY, and the applications are what it is
        // bound to — which is the edge worth having in the graph. This used to
        // file the subject as `kind: "app"` and then look the ability back up
        // through `AmbientWorld.from(pluginOwner:)`, a lookup that returns nil
        // for every DYNAMIC package: Scrivener's ability edge would silently
        // have gone missing, which is exactly the case the reframe is about.
        var entities = [TotemEntityIn(name: subject, kind: "ability")]
        var relationships: [TotemRelationIn] = []
        for application in applications {
            entities.append(TotemEntityIn(name: application, kind: "app"))
            relationships.append(TotemRelationIn(
                subject: subject, predicate: "applies to", object: application))
        }

        let destination = ("mary-context-\(owner)", "Mary Context")
        let item = DepositItem(
            documentID: TotemMemoryTopology.styleProfileDocumentID(
                subject: subject, ownerID: owner),
            texts: [content],
            tags: ["mary", "style-profile", subject],
            name: "\(subject) style profile",
            metadata: Data(),
            entities: entities,
            relationships: relationships)
        _ = try? await client.deposit(
            [item], ownerID: owner,
            groupID: destination.0, groupLabel: destination.1)
    }

    /// Restore the profile. A profile this build cannot read is refused by the
    /// codec rather than half-applied.
    func loadStyleProfile(
        subject: String
    ) async -> (tenets: [StyleTenet], vetoedTenetKeys: [String]) {
        guard let owner = await session.userID else { return ([], []) }
        let id = TotemMemoryTopology.styleProfileDocumentID(subject: subject, ownerID: owner)
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

    /// EVERY RELATIONSHIP ENDPOINT SHIPS AS AN ENTITY. Totem drops a relation
    /// whose subject or object does not match an entity name in the same item,
    /// and an item carrying relations but no entities loses them entirely to
    /// LLM re-extraction. So the entity set is derived FROM the relations
    /// rather than assembled beside them — the two cannot drift.
    static func unitComposition(
        _ unit: IndexedUnit
    ) -> (entities: [TotemEntityIn], relationships: [TotemRelationIn]) {
        var relationships = unit.relations.map {
            TotemRelationIn(
                subject: $0.subject, predicate: $0.predicate.rawValue, object: $0.object)
        }
        for label in unit.annotation?.labels ?? [] {
            relationships.append(TotemRelationIn(
                subject: unit.relativePath,
                predicate: UnitRelationPredicate.expresses.rawValue,
                object: label))
        }
        if let discipline = unit.discipline {
            relationships.append(TotemRelationIn(
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
            TotemEntityIn(name: $0, kind: kinds[$0] ?? "type")
        }
        return (entities, relationships)
    }

    // A `persistApplicationSchemaManifest` stood here, writing the durable
    // half of the application-schema OBSERVER — the coordinator C2 declined to
    // port, because Mary's packages state what an application is rather than
    // having it guessed at. With nothing producing those facts there is
    // nothing to persist, and a writer for a store that is never written is
    // worse than absent: it looks like a feature.

}
