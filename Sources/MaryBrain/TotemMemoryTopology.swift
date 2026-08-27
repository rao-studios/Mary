import Foundation

/// Names the two logical Totems while they share the local Totem service.
public enum TotemMemoryTopology {
    public static func applicationGroup(
        applicationID: String, ownerID: String
    ) -> RetrievalScope.Group {
        let key = canonical(ownerID) + "|" + canonical(applicationID)
        return .init(
            id: "mary-application-\(hash(key))",
            label: "Application — \(applicationID)")
    }

    public static func applicationDocumentID(applicationID: String, ownerID: String) -> String {
        "mary-application-document-\(hash(canonical(ownerID) + "|" + canonical(applicationID)))"
    }

    /// One durable document per learned application relationship. Keeping the
    /// fact id in the address lets a new observation replace only that fact,
    /// so schema growth never rewrites an unrelated capability or workflow.
    public static func applicationSchemaDocumentID(
        applicationID: String,
        schemaID: String,
        ownerID: String
    ) -> String {
        let key = [canonical(ownerID), canonical(applicationID), canonical(schemaID)]
            .joined(separator: "|")
        return "mary-application-schema-\(hash(key))"
    }

    /// The structural snapshot for one project. It is separate from episodic
    /// action records so an idle re-index replaces the old binder shape rather
    /// than accumulating one document per watcher poll.
    public static func projectSchemaDocumentID(projectID: String, ownerID: String) -> String {
        "mary-project-schema-\(hash(canonical(ownerID) + "|" + canonical(projectID)))"
    }

    /// A compact durable catalogue for one application's active schema facts.
    /// It lets a new Mary process resume evidence and retire stale facts
    /// instead of treating every launch as a fresh integration.
    public static func applicationSchemaManifestID(applicationID: String, ownerID: String) -> String {
        "mary-application-schema-manifest-\(hash(canonical(ownerID) + "|" + canonical(applicationID)))"
    }

    // MARK: - Unit index
    //
    // OWNER-FREE IDENTITY, OWNER-SCOPED PLACEMENT. `IndexedUnit.unitKey` is
    // derived from project and path alone and carries no owner, no machine,
    // and no node; the owner enters only here, when the unit is given a place
    // to live. That split is what lets the same unit be re-addressed under a
    // different owner without changing what it is. Owner stays in the address
    // because one Totem DB holds many owners and an un-owned group id would be
    // dropped as already-owned — the reason `DepositSubject` gives.
    //

    public static func retrievalScope(
        for plan: TotemMemoryPlan,
        subject: DepositSubject,
        ownerID: String
    ) -> RetrievalScope {
        let applicationGroups = plan.applicationIDs.map {
            applicationGroup(applicationID: $0, ownerID: ownerID)
        }
        guard plan.lanes.contains(.application) else {
            return subject.retrievalScope(ownerID: ownerID)
        }
        guard plan.lanes.contains(.personal) else {
            return RetrievalScope(
                groups: applicationGroups,
                aggregate: false,
                relationshipHints: plan.relationshipHints)
        }

        let personal = subject.retrievalScope(ownerID: ownerID)
        let personalGroups = personal.aggregate
            ? RetrievalScope.memoryGroups(ownerID: ownerID) + [RetrievalScope.legacyPool(ownerID: ownerID)]
            : personal.groups
        let groupsByLane: [TotemLane: [RetrievalScope.Group]] = [
            .application: applicationGroups,
            .personal: personalGroups,
        ]
        let ordered = plan.lanePriority.flatMap { groupsByLane[$0] ?? [] }
        return RetrievalScope(
            groups: unique(ordered),
            aggregate: false,
            relationshipHints: plan.relationshipHints)
    }

    private static func unique(_ groups: [RetrievalScope.Group]) -> [RetrievalScope.Group] {
        var seen = Set<String>()
        return groups.filter { seen.insert($0.id).inserted }
    }

    private static func canonical(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    private static func hash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}
