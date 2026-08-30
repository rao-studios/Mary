//
//  TotemContextStore+UnitIndex.swift
//

import MaryBrain
import MaryTotem
import Foundation

extension TotemContextStore {

    // MARK: - Unit index

    /// Files one card per indexed unit into the project's own personal-lane
    /// group, and refreshes that project's catalogue.
    ///
    /// WHY THE LABELS ARE IN THE TEXT. `PartitionHit` returns only
    /// `{totemID, partitionID, documentID, ownerID, text, score}` — tags do
    /// not come back, metadata does not come back, and there is no timestamp.
    /// So the concept labels ride the document BODY and the entity graph,
    /// where retrieval can actually reach them. Putting them solely in `tags:`
    /// would deposit cleanly and be permanently unfindable, which is the
    /// failure that looks most like success.
    /// THE MANIFEST ARRIVES WITH THE UNIT. It used to be rebuilt here from
    /// scratch, which made this store a SECOND owner of the same state — so a
    /// hand-pinned label updated the coordinator's copy and not this one, and
    /// the two drifted with nothing to notice. The coordinator owns it now;
    /// this only writes it down.
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

    /// Restores one project's catalogue so a relaunch resumes. A manifest
    /// whose format this build cannot read is refused rather than half-applied
    /// — the caller starts fresh, which loses learning but never mixes two
    /// formats.
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
