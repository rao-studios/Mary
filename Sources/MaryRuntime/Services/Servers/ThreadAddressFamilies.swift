//
//  ThreadAddressFamilies.swift
//  MaryRuntime
//
//  WHAT: Which family a Thread address belongs to, from the id prefix alone.
//  IN:   MaryAmbient / MaryBrain / Runtime minters
//  PIN:  Library returns neither tags nor metadata — prefixes are the only map.
//

import MaryFoundation

/// Address families in the shared Thread node. Each case names the minter that spells its prefix.
package enum ThreadAddressFamily: String, CaseIterable {

    // MARK: Group families

    /// `mary-ability-…` — `ThreadMemoryTopology.abilityGroup`.
    case abilityGroup
    /// `mary-scope-…` — `DepositSubject.groupID`.
    case scopeGroup
    /// `mary-behavior-interaction-<owner>` — `ThreadMemoryTopology.interactionGroup`.
    case behaviorInteraction
    /// `mary-style-<owner>` — `ThreadMemoryTopology.styleGroup`.
    case styleGroup
    /// `mary-routing-<owner>` — `ThreadContextStore.routingHabitGroup`.
    case routingGroup
    /// `mary-habit-<owner>` — `ThreadMemoryTopology.applicationHabitGroup`.
    case applicationHabitGroup
    /// `memory-<owner>` — written by the Sewn server, never by Mary.
    case sewnMemory
    /// `resonance-<owner>` — written by the Sewn server, never by Mary.
    case sewnResonance

    // MARK: Document families

    /// `mary-ability-document-…` — `ThreadMemoryTopology.abilityDocumentID`.
    case abilityDocument
    /// `mary-ability-schema-manifest-…` — `ThreadMemoryTopology.abilitySchemaManifestID`.
    case abilitySchemaManifest
    /// `mary-ability-schema-…` — `ThreadMemoryTopology.abilitySchemaDocumentID`.
    case abilitySchema
    /// `mary-project-schema-…` — `ThreadMemoryTopology.projectSchemaDocumentID`.
    case projectSchema
    /// `mary-doc-…` — `DepositSubject.stateDocumentID`. The lane and
    /// projection suffixes `ThreadContextStore.documentID` append keep the
    /// prefix, so suffixed snapshots stay in this family.
    case stateSnapshot
    /// `mary-skill-<uuid>` — leftover episodic skill dumps; no longer minted.
    case skillRecord
    /// `mary-unit-manifest-…` — `ThreadMemoryTopology.unitManifestID`.
    case unitManifest
    /// `mary-unit-…` — `ThreadMemoryTopology.unitDocumentID`.
    case unitCard
    /// `mary-style-profile-…` — `ThreadMemoryTopology.styleProfileDocumentID`.
    case styleProfile
    /// `mary-behavior-interaction-…` — Personal interaction stub.
    case behaviorInteractionDocument
    /// `mary-behavior-…` — sealed BehavioralEpisode on Ability Thread.
    case behaviorEpisode
    /// `mary-routing-<intent>|<skill>|<epoch>` — one settled routing habit.
    /// The label rides in the id because a thread search returns no metadata.
    case routingHabit
    /// `mary-habit-ledger-…` — `ThreadMemoryTopology.applicationHabitLedgerDocumentID`.
    case applicationHabitLedger

    /// Unknown prefix — own bucket, not folded into a neighbour.
    case unknown
}

/// A family plus what it implies. Lane and ownership are derived here, in
/// one switch, so a classification can never carry a lane its family does
/// not have.
package struct ThreadAddressClassification: Equatable {
    package var family: ThreadAddressFamily
    /// The projection lane the family's minter deposits into. Nil for the
    /// Sewn-owned groups (the server has no lanes) and for `.unknown`.
    package var lane: ThreadLane?
    /// True for groups the Sewn server writes on its own. Repair and cleanup
    /// actions must never treat those as Mary's to rewrite.
    package var isSewnOwned: Bool

    init(family: ThreadAddressFamily) {
        self.family = family
        switch family {
        case .abilityGroup, .abilityDocument,
             .abilitySchemaManifest, .abilitySchema, .behaviorEpisode:
            lane = .ability
        case .scopeGroup, .behaviorInteraction, .styleGroup, .projectSchema,
             .stateSnapshot, .skillRecord, .unitManifest, .unitCard,
             .styleProfile, .behaviorInteractionDocument,
             .routingGroup, .routingHabit,
             .applicationHabitGroup, .applicationHabitLedger:
            lane = .personal
        case .sewnMemory, .sewnResonance, .unknown:
            lane = nil
        }
        isSewnOwned = family == .sewnMemory || family == .sewnResonance
    }
}

/// Prefix classification. Group ids and document ids are separate namespaces.
package enum ThreadAddressClassifier {

    package static func classifyGroup(id: String) -> ThreadAddressClassification {
        classify(id, in: groupTable)
    }

    package static func classifyDocument(id: String) -> ThreadAddressClassification {
        classify(id, in: documentTable)
    }

    // Longest prefix first — families share spines (ability-schema-manifest, unit-manifest, …).

    private static let groupTable: [(prefix: String, family: ThreadAddressFamily)] =
        byLongestPrefix([
            ("mary-behavior-interaction-", .behaviorInteraction),
            ("mary-ability-", .abilityGroup),
            ("mary-scope-", .scopeGroup),
            ("mary-style-", .styleGroup),
            ("mary-routing-", .routingGroup),
            ("mary-habit-", .applicationHabitGroup),
            ("memory-", .sewnMemory),
            ("resonance-", .sewnResonance),
        ])

    private static let documentTable: [(prefix: String, family: ThreadAddressFamily)] =
        byLongestPrefix([
            ("mary-ability-schema-manifest-", .abilitySchemaManifest),
            ("mary-ability-schema-", .abilitySchema),
            ("mary-ability-document-", .abilityDocument),
            ("mary-behavior-interaction-", .behaviorInteractionDocument),
            ("mary-behavior-", .behaviorEpisode),
            ("mary-project-schema-", .projectSchema),
            ("mary-doc-", .stateSnapshot),
            ("mary-skill-", .skillRecord),
            ("mary-unit-manifest-", .unitManifest),
            ("mary-unit-", .unitCard),
            ("mary-style-profile-", .styleProfile),
            ("mary-routing-", .routingHabit),
            ("mary-habit-ledger-", .applicationHabitLedger),
        ])

    private static func classify(
        _ id: String,
        in table: [(prefix: String, family: ThreadAddressFamily)]
    ) -> ThreadAddressClassification {
        for entry in table where id.hasPrefix(entry.prefix) {
            return ThreadAddressClassification(family: entry.family)
        }
        return ThreadAddressClassification(family: .unknown)
    }

    private static func byLongestPrefix(
        _ rows: [(prefix: String, family: ThreadAddressFamily)]
    ) -> [(prefix: String, family: ThreadAddressFamily)] {
        rows.sorted { $0.prefix.count > $1.prefix.count }
    }
}
