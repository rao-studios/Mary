//
//  TotemExplorerRows.swift
//
//  Split out of TotemExplorerViewModel.swift (docs/DECOMPOSITION.md
//  Wave 2) — pure relocation, no declaration changed.
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryTotem
import Foundation
import SwiftUI
import MaryRuntime

// MARK: - Nodes rows

struct TotemFleetHeader: Equatable {
    var mothershipID: String
    var totalDocumentCount: Int
    var totalGroupCount: Int
    /// Seer's honest "no fleet" (zero registered nodes), distinct from
    /// "fleet unreachable" — which is a notice, not a header.
    var enabled: Bool
    var nodeCount: Int
}

struct TotemNodeRow: Identifiable, Equatable {
    var id: String
    var host: String
    var portLine: String
    var lastSeen: Date
    var lastSeenLine: String
    var isActive: Bool
    var acceptingStorage: Bool
    /// The live-node identity diff: this fleet row is the node the local
    /// configuration (or the persisted node-id file) says Mary loads.
    var isConfiguredNode: Bool
    var stats: TotemNodeStats?
    /// Rendered here rather than in the view, so the pure builder decides
    /// what the pane says about a node's holdings.
    var statsLine: String?
}

struct TotemDiskRow: Identifiable, Equatable {
    var id: String
    var isLive: Bool
    /// Which of the table/graph/registry triple actually flushed — orphans
    /// often kept only part of it.
    var layersLine: String
    var bytes: Int64
    var sizeLine: String
    var lastModified: Date?
    var modifiedLine: String?

    var isOrphan: Bool { !isLive }
}

struct TotemDiskSummary: Equatable {
    var root: String
    var liveNodeID: String?
    var nodeCount: Int
    var orphanCount: Int
    var documentCount: Int
    var partsCount: Int
    var totalBytes: Int64
    var totalLine: String
}

// MARK: - Library rows

struct TotemFamilyChip: Identifiable, Equatable {
    var family: TotemAddressFamily
    var title: String
    var count: Int

    var id: String { family.rawValue }
}

struct TotemDocumentRow: Identifiable, Equatable {
    var id: String
    var name: String
    var createdAt: Date?
    var family: TotemAddressFamily
    var familyTitle: String
}

struct TotemGroupRow: Identifiable, Equatable {
    var id: String
    var label: String
    var documentCount: Int
    var family: TotemAddressFamily
    var familyTitle: String
    var lane: TotemLane?
    var isSeerOwned: Bool
    var documents: [TotemDocumentRow]
}

struct TotemLaneSection: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var groups: [TotemGroupRow]
}

/// One drilled document, as a snapshot: either the full body (Documents RPC)
/// or the ContributionInspector fallback tier — library metadata plus a
/// search-hit preview — with the degradation NAMED in `notice`.
struct TotemDocumentDetail: Identifiable, Equatable {
    var id: String
    var name: String
    var groupLabel: String
    var createdAt: Date?
    /// Partition texts joined in stored order. Nil when only the fallback
    /// tier could answer.
    var body: String?
    /// Fallback preview from a name-seeded search hit.
    var preview: String?
    var family: TotemAddressFamily
    var notice: String?
    var codec: BehavioralCodecView? = nil
    var interaction: BehavioralInteractionStub? = nil
}

// MARK: - Graph

/// The request as the panel shapes it — pure, so the clamp is pinnable.
struct TotemGraphRequestShape: Equatable {
    var query: String
    var kinds: [String]
    var hops: Int
    var limit: Int
    var includeDocuments: Bool
}

// MARK: - Ledger rows

// MARK: - Retrieval rows (built side)

struct TotemScopeGroupTag: Identifiable, Equatable {
    var id: String
    var label: String
    var family: TotemAddressFamily
    var familyTitle: String
}

struct TotemRetrievalRequestRow: Identifiable, Equatable {
    /// The wire `requestID` — how the pane says which request the
    /// contribution answered.
    var id: String
    var transport: SeerTransportKind
    var aggregate: Bool
    var groups: [TotemScopeGroupTag]
    var relationshipHints: [String]
    var isAnswered: Bool
}

struct TotemMemoryPlanRow: Equatable {
    var lanes: [String]
    var abilityTargets: [String]
    var expandDisciplineUsage: Bool
    var lanePriority: [String]
    var relationshipHints: [String]
}

/// A derivation the pure builder computed and the panel exists to show.
/// Derived every build, NEVER stored — a cached warning about live ledgers
/// is a stale claim.
struct TotemRetrievalWarning: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case behaviouralCorpusUnreachable
        case planScopeMismatch
        case askedNothingBack
        case ambientBudgetPressure
        case waterfallMismatch
    }

    var kind: Kind
    var message: String

    /// Message participates because one row can carry the same kind twice
    /// (one budget/waterfall warning per prompt lane).
    var id: String { kind.rawValue + "|" + message }
}

/// One turn's retrieval story. Partial rows are NAMED STATES, never dropped:
/// a route with no retrieval, or a ledger row with no route, is still a row.
struct TotemRetrievalTurnRow: Identifiable, Equatable {
    var id: String
    var date: Date
    var utterance: String?
    /// intent · decidedBy · rankingMode, from the joined route row.
    var routeLine: String?
    var plan: TotemMemoryPlanRow?
    var requests: [TotemRetrievalRequestRow]
    var contribution: SeerContributionTrace?
    var ambient: [AmbientInjectionTrace]
    var promptSpend: [PromptSpendTrace]
    /// The named partial state ("no retrieval asked", "no route row…"), nil
    /// for a complete row.
    var state: String?
    var warnings: [TotemRetrievalWarning]
}
