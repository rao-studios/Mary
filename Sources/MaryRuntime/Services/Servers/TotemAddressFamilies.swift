//
//  TotemAddressFamilies.swift
//  Mary
//
//  WHICH FAMILY A TOTEM ADDRESS BELONGS TO, from the id alone. Totem's tags
//  and metadata are write-only — the library returns neither — so the lane
//  and family of everything in the node can only be recovered from the
//  address prefixes the minters chose. This lives in the app layer because
//  the app is the only layer that sees every minter: MaryAmbient mints
//  mary-scope-/mary-doc- (and spells Seer's own memory-/resonance- groups),
//  MaryBrain mints mary-ability-*/mary-unit-*/mary-style-profile-/
//  mary-project-schema-/mary-behavior-*, and the runtime mints
//  mary-behavior-interaction- / mary-style- groups.
//

import MaryFoundation

/// Every address family minted into the shared Totem node, group and
/// document alike. Each case documents the ONE function that spells its
/// prefix — the round-trip tests classify ids produced by those very
/// functions, so this enum cannot quietly disagree with a minter.
package enum TotemAddressFamily: String, CaseIterable {

    // MARK: Group families

    /// `mary-ability-…` — `TotemMemoryTopology.abilityGroup`.
    case abilityGroup
    /// `mary-scope-…` — `DepositSubject.groupID`.
    case scopeGroup
    /// `mary-behavior-interaction-<owner>` — `TotemMemoryTopology.interactionGroup`.
    case behaviorInteraction
    /// `mary-style-<owner>` — `TotemMemoryTopology.styleGroup`.
    case styleGroup
    /// `memory-<owner>` — written by the Seer server, never by Mary.
    case seerMemory
    /// `resonance-<owner>` — written by the Seer server, never by Mary.
    case seerResonance

    // MARK: Document families

    /// `mary-ability-document-…` — `TotemMemoryTopology.abilityDocumentID`.
    case abilityDocument
    /// `mary-ability-schema-manifest-…` — `TotemMemoryTopology.abilitySchemaManifestID`.
    case abilitySchemaManifest
    /// `mary-ability-schema-…` — `TotemMemoryTopology.abilitySchemaDocumentID`.
    case abilitySchema
    /// `mary-project-schema-…` — `TotemMemoryTopology.projectSchemaDocumentID`.
    case projectSchema
    /// `mary-doc-…` — `DepositSubject.stateDocumentID`. The lane and
    /// projection suffixes `TotemContextStore.documentID` append keep the
    /// prefix, so suffixed snapshots stay in this family.
    case stateSnapshot
    /// `mary-skill-<uuid>` — leftover episodic skill dumps; no longer minted.
    case skillRecord
    /// `mary-unit-manifest-…` — `TotemMemoryTopology.unitManifestID`.
    case unitManifest
    /// `mary-unit-…` — `TotemMemoryTopology.unitDocumentID`.
    case unitCard
    /// `mary-style-profile-…` — `TotemMemoryTopology.styleProfileDocumentID`.
    case styleProfile
    /// `mary-behavior-interaction-…` — Personal interaction stub.
    case behaviorInteractionDocument
    /// `mary-behavior-…` — sealed BehavioralEpisode on Ability Totem.
    case behaviorEpisode

    /// No minter Mary knows about. Kept as its own bucket rather than
    /// folded into a nearest neighbour, so foreign or future addresses show
    /// up in the pane as what they are instead of being misfiled into a lane.
    case unknown
}

/// A family plus what it implies. Lane and ownership are derived here, in
/// one switch, so a classification can never carry a lane its family does
/// not have.
package struct TotemAddressClassification: Equatable {
    package var family: TotemAddressFamily
    /// The projection lane the family's minter deposits into. Nil for the
    /// Seer-owned groups (the server has no lanes) and for `.unknown`.
    package var lane: TotemLane?
    /// True for groups the Seer server writes on its own. Repair and cleanup
    /// actions must never treat those as Mary's to rewrite.
    package var isSeerOwned: Bool

    init(family: TotemAddressFamily) {
        self.family = family
        switch family {
        case .abilityGroup, .abilityDocument,
             .abilitySchemaManifest, .abilitySchema, .behaviorEpisode:
            lane = .ability
        case .scopeGroup, .behaviorInteraction, .styleGroup, .projectSchema,
             .stateSnapshot, .skillRecord, .unitManifest, .unitCard,
             .styleProfile, .behaviorInteractionDocument:
            lane = .personal
        case .seerMemory, .seerResonance, .unknown:
            lane = nil
        }
        isSeerOwned = family == .seerMemory || family == .seerResonance
    }
}

/// Pure prefix classification. Group ids and document ids are separate
/// namespaces with separate callers (the library lists groups; drill-down
/// lists documents), so each gets its own table — a document id fed to the
/// group classifier is not a supported question.
package enum TotemAddressClassifier {

    package static func classifyGroup(id: String) -> TotemAddressClassification {
        classify(id, in: groupTable)
    }

    package static func classifyDocument(id: String) -> TotemAddressClassification {
        classify(id, in: documentTable)
    }

    // CORRECTNESS RULE — LONGEST PREFIX FIRST. Several families share a
    // spine: `mary-ability-schema-manifest-` begins with
    // `mary-ability-schema-`, which begins with `mary-ability-`;
    // `mary-unit-manifest-` begins with `mary-unit-`;
    // `mary-behavior-interaction-` begins with `mary-behavior-`.

    private static let groupTable: [(prefix: String, family: TotemAddressFamily)] =
        byLongestPrefix([
            ("mary-behavior-interaction-", .behaviorInteraction),
            ("mary-ability-", .abilityGroup),
            ("mary-scope-", .scopeGroup),
            ("mary-style-", .styleGroup),
            ("memory-", .seerMemory),
            ("resonance-", .seerResonance),
        ])

    private static let documentTable: [(prefix: String, family: TotemAddressFamily)] =
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
        ])

    private static func classify(
        _ id: String,
        in table: [(prefix: String, family: TotemAddressFamily)]
    ) -> TotemAddressClassification {
        for entry in table where id.hasPrefix(entry.prefix) {
            return TotemAddressClassification(family: entry.family)
        }
        return TotemAddressClassification(family: .unknown)
    }

    private static func byLongestPrefix(
        _ rows: [(prefix: String, family: TotemAddressFamily)]
    ) -> [(prefix: String, family: TotemAddressFamily)] {
        rows.sorted { $0.prefix.count > $1.prefix.count }
    }
}
