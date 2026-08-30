import Foundation
import MaryAmbient
import MaryFoundation

/// Names the two logical Totems while they share the local Totem service.
public enum TotemMemoryTopology {
    public static func abilityGroup(
        target: AbilityTotemTarget, ownerID: String
    ) -> RetrievalScope.Group {
        let key = [
            canonical(ownerID),
            canonical(target.abilityID.rawValue),
            canonical(target.paradigm.rawValue),
        ].joined(separator: "|")
        return .init(
            id: "mary-ability-\(hash(key))",
            label: "Ability — \(target.label)")
    }

    public static func abilityDocumentID(
        target: AbilityTotemTarget, ownerID: String
    ) -> String {
        let key = [
            canonical(ownerID),
            canonical(target.abilityID.rawValue),
            canonical(target.paradigm.rawValue),
        ].joined(separator: "|")
        return "mary-ability-document-\(hash(key))"
    }

    /// One durable document per learned ability relationship. Keeping the
    /// fact id in the address lets a new observation replace only that fact,
    /// so schema growth never rewrites an unrelated capability or workflow.
    public static func abilitySchemaDocumentID(
        target: AbilityTotemTarget,
        schemaID: String,
        ownerID: String
    ) -> String {
        let key = [
            canonical(ownerID),
            canonical(target.abilityID.rawValue),
            canonical(target.paradigm.rawValue),
            canonical(schemaID),
        ].joined(separator: "|")
        return "mary-ability-schema-\(hash(key))"
    }

    /// The structural snapshot for one project. It is separate from episodic
    /// action records so an idle re-index replaces the old binder shape rather
    /// than accumulating one document per watcher poll.
    public static func projectSchemaDocumentID(projectID: String, ownerID: String) -> String {
        "mary-project-schema-\(hash(canonical(ownerID) + "|" + canonical(projectID)))"
    }

    /// A compact durable catalogue for one Ability's active schema facts.
    /// It lets a new Mary process resume evidence and retire stale facts
    /// instead of treating every launch as a fresh integration.
    public static func abilitySchemaManifestID(
        target: AbilityTotemTarget, ownerID: String
    ) -> String {
        let key = [
            canonical(ownerID),
            canonical(target.abilityID.rawValue),
            canonical(target.paradigm.rawValue),
        ].joined(separator: "|")
        return "mary-ability-schema-manifest-\(hash(key))"
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

    /// Seer chat: Personal interaction records plus Seer's own memory.
    /// Never Ability groups, never project scopes, never `mary-context-*`.
    public static func seerPersonalScope(ownerID: String) -> RetrievalScope {
        RetrievalScope(
            groups: [interactionGroup(ownerID: ownerID)]
                + RetrievalScope.memoryGroups(ownerID: ownerID),
            aggregate: false)
    }

    /// Same as `seerPersonalScope(ownerID:)` — subject no longer steers Seer.
    public static func seerPersonalScope(
        subject: DepositSubject,
        ownerID: String
    ) -> RetrievalScope {
        seerPersonalScope(ownerID: ownerID)
    }

    public static func interactionGroup(ownerID: String) -> RetrievalScope.Group {
        .init(id: "mary-behavior-interaction-\(ownerID)", label: "Interactions")
    }

    public static func styleGroup(ownerID: String) -> RetrievalScope.Group {
        .init(id: "mary-style-\(ownerID)", label: "Style")
    }

    public static func behaviorDocumentID(episodeID: UUID) -> String {
        "mary-behavior-\(episodeID.uuidString.lowercased())"
    }

    public static func interactionDocumentID(episodeID: UUID) -> String {
        "mary-behavior-interaction-\(episodeID.uuidString.lowercased())"
    }

    /// Ability Totem groups Mary searches over gRPC. Empty when the turn has
    /// no Ability targets — skip the search rather than scanning Personal.
    public static func maryAbilityScope(
        for plan: TotemMemoryPlan,
        ownerID: String
    ) -> RetrievalScope {
        let abilityGroups = plan.abilityTargets.map {
            abilityGroup(target: $0, ownerID: ownerID)
        }
        var hints = plan.relationshipHints
        if plan.expandDisciplineUsage {
            hints.append("practices")
            hints.append(contentsOf: plan.abilityTargets
                .filter { $0.paradigm == .discipline }
                .map(\.abilityID.rawValue))
            hints = Array(Set(hints)).sorted()
        }
        return RetrievalScope(
            groups: unique(abilityGroups),
            aggregate: false,
            relationshipHints: hints)
    }

    /// Combined scope kept for callers that still ask "the whole plan".
    /// Seer chat must use `seerPersonalScope`; Mary's gRPC search must use
    /// `maryAbilityScope`.
    public static func retrievalScope(
        for plan: TotemMemoryPlan,
        subject: DepositSubject,
        ownerID: String
    ) -> RetrievalScope {
        seerPersonalScope(subject: subject, ownerID: ownerID)
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

    /// One durable profile per application subject. Tenets are scoped
    /// internally (language / application / project), so they travel together
    /// in one document rather than being scattered across per-scope addresses
    /// that would have to be re-joined to answer any question about them.
    public static func styleProfileDocumentID(subject: String, ownerID: String) -> String {
        let key = UnitIndexHashing.canonical(ownerID) + "|" + UnitIndexHashing.canonical(subject)
        return "mary-style-profile-\(UnitIndexHashing.stableHash(key))"
    }

    /// One durable document per indexed file. Keying on the unit rather than
    /// the project is what lets a neighbourhood accumulate — moving to a
    /// second file adds a card instead of rewriting the first.
    public static func unitDocumentID(unitKey: String, ownerID: String) -> String {
        let key = UnitIndexHashing.canonical(ownerID) + "|" + unitKey
        return "mary-unit-\(UnitIndexHashing.stableHash(key))"
    }

    /// The compact per-project catalogue of what has already been indexed and
    /// at which revision, so a relaunch resumes instead of re-reading the
    /// whole project.
    public static func unitManifestID(projectID: String, ownerID: String) -> String {
        let key = UnitIndexHashing.canonical(ownerID) + "|" + UnitIndexHashing.canonical(projectID)
        return "mary-unit-manifest-\(UnitIndexHashing.stableHash(key))"
    }

}
