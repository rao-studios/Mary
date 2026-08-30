//
//  TotemExplorerRows.swift
//  Mary
//
//  WHAT: Pure row models for the Totems pane.
//  IN:   TotemExplorerViewModel (sibling split)
//  OUT:  Totems*View
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
    /// Seer's honest "no fleet" (zero nodes). Unreachable is a notice, not a header.
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
    /// Live-node identity: this row is the node config (or persisted node-id) says Mary loads.
    var isConfiguredNode: Bool
    var stats: TotemNodeStats?
    /// Built here so the pane speaks the builder's line, not the view's.
    var statsLine: String?
}

struct TotemDiskRow: Identifiable, Equatable {
    var id: String
    var isLive: Bool
    /// Which of table/graph/registry flushed — orphans often kept only part.
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

/// Drilled document snapshot. Full body or ContributionInspector fallback; degradation named in `notice`.
struct TotemDocumentDetail: Identifiable, Equatable {
    var id: String
    var name: String
    var groupLabel: String
    var createdAt: Date?
    /// Partition texts in stored order. Nil when only the fallback tier answered.
    var body: String?
    /// Fallback preview from a name-seeded search hit.
    var preview: String?
    var family: TotemAddressFamily
    var notice: String?
    var codec: BehavioralCodecView? = nil
    var interaction: BehavioralInteractionStub? = nil
}

// MARK: - Graph

/// Request as the panel shapes it — pure, so the clamp is pinnable.
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
    /// Wire `requestID` — which request the contribution answered.
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

/// Builder-computed warning. Derived every build, never stored (live ledgers go stale).
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

    /// Same kind can appear twice (one budget/waterfall warning per prompt lane).
    var id: String { kind.rawValue + "|" + message }
}

/// One turn's retrieval. Partial rows are named states, never dropped.
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
    /// Named partial ("no retrieval asked", "no route row…"); nil when complete.
    var state: String?
    var warnings: [TotemRetrievalWarning]
}
