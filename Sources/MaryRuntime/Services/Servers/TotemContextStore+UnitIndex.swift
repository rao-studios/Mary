//
//  TotemContextStore+UnitIndex.swift
//  MaryRuntime
//
//  WHAT: Per-project unit-index manifests in Totem.
//  OUT:  TotemDirectClient
//

import MaryBrain
import MaryTotem
import Foundation

extension TotemContextStore {

    // MARK: - Unit index

    /// One card per indexed unit into the project's group; refresh the catalogue.
    /// Labels ride the document body (PartitionHit returns no tags). Coordinator owns the manifest.
    func depositUnitIndex(_ unit: IndexedUnit, manifest: UnitIndexManifest) async {
        guard let owner = await session.userID,
              let projectID = unit.projectID, !projectID.isEmpty,
              let destination = Self.destination(subject: unit.subject, ownerID: owner)
        else { return }
        let composition = Self.unitComposition(unit)
        let documentID = TotemMemoryTopology.unitDocumentID(
            unitKey: unit.unitKey, ownerID: owner)

        let item = DepositItem(
            documentID: documentID,
            texts: [Self.unitDocument(unit)],
            tags: ["mary", "project", "code-unit", unit.subject.app ?? "workspace"]
                + (unit.annotation?.labels ?? []),
            name: "\(unit.projectName) — \(unit.relativePath)",
            metadata: Self.unitMetadata(unit),
            entities: composition.entities,
            relationships: composition.relationships)
        do {
            try await client.deposit(
                [item], ownerID: owner,
                groupID: destination.id, groupLabel: destination.label)
        } catch {
            UnitIndexLedger.shared.noteDeposit(.failed, forUnit: unit.unitKey)
            return
        }
        UnitIndexLedger.shared.noteDeposit(
            .deposited, documentID: documentID, forUnit: unit.unitKey)

        unitManifests[projectID] = manifest
        if let app = unit.subject.app, !app.isEmpty {
            unitManifestOwners[projectID] = app
        }
        await persistUnitManifest(
            projectID: projectID, projectName: unit.projectName, ownerID: owner)
    }

    /// Remove one unit's document. The coordinator's manifest row is dropped
    /// by the caller; this is the durable half.
    @discardableResult
    package func forgetUnit(unitKey: String) async -> Bool {
        guard let owner = await session.userID else { return false }
        let documentID = TotemMemoryTopology.unitDocumentID(
            unitKey: unitKey, ownerID: owner)
        guard (try? await client.remove(documentIDs: [documentID], ownerID: owner)) != nil
        else { return false }
        UnitIndexLedger.shared.noteForgotten(unitKey: unitKey)
        return true
    }

    /// Persist a manifest the coordinator has changed without a deposit —
    /// pinning a label, forgetting a unit, invalidating a hash gate.
    func persistUnitManifest(
        _ manifest: UnitIndexManifest, projectID: String, projectName: String
    ) async {
        guard let owner = await session.userID, !projectID.isEmpty else { return }
        unitManifests[projectID] = manifest
        await persistUnitManifest(
            projectID: projectID, projectName: projectName, ownerID: owner)
    }

    /// Restore one project's catalogue. Unreadable format is refused, not half-applied.
    func loadUnitManifest(projectID: String) async -> UnitIndexManifest? {
        guard let owner = await session.userID, !projectID.isEmpty else { return nil }
        let id = TotemMemoryTopology.unitManifestID(projectID: projectID, ownerID: owner)
        guard let documents = try? await client.documents(ids: [id], ownerID: owner),
              let content = documents.first?.content,
              let data = content.data(using: .utf8),
              let manifest = try? UnitIndexManifest.decoder()
                  .decode(UnitIndexManifest.self, from: data),
              manifest.isReadable
        else { return nil }
        unitManifests[projectID] = manifest
        return manifest
    }

    private func persistUnitManifest(
        projectID: String, projectName: String, ownerID: String
    ) async {
        guard let manifest = unitManifests[projectID],
              let data = try? UnitIndexManifest.encoder().encode(manifest),
              let content = String(data: data, encoding: .utf8),
              let destination = Self.destination(
                subject: DepositSubject(
                    app: unitManifestOwners[projectID], projectIdentity: projectID),
                ownerID: ownerID)
        else { return }
        let item = DepositItem(
            documentID: TotemMemoryTopology.unitManifestID(
                projectID: projectID, ownerID: ownerID),
            texts: [content],
            tags: ["mary", "project", "unit-manifest"],
            name: "\(projectName) index",
            metadata: Data(),
            entities: [TotemEntityIn(name: projectName, kind: "project")],
            relationships: [])
        _ = try? await client.deposit(
            [item], ownerID: ownerID,
            groupID: destination.id, groupLabel: destination.label)
    }

}
