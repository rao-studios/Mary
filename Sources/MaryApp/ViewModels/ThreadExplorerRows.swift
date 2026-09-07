//
//  ThreadExplorerRows.swift
//  Mary
//
//  WHAT: Pure row models for the Threads pane.
//  IN:   ThreadExplorerViewModel (sibling split)
//  OUT:  Threads*View
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryThread
import Foundation
import SwiftUI
import MaryRuntime

// MARK: - Nodes rows

struct ThreadFleetHeader: Equatable {
    var mothershipID: String
    var totalDocumentCount: Int
    var totalGroupCount: Int
    /// Sewn's honest "no fleet" (zero nodes). Unreachable is a notice, not a header.
    var enabled: Bool
    var nodeCount: Int
}

struct ThreadNodeRow: Identifiable, Equatable {
    var id: String
    var host: String
    var portLine: String
    var lastSeen: Date
    var lastSeenLine: String
    var isActive: Bool
    var acceptingStorage: Bool
    /// Live-node identity: this row is the node config (or persisted node-id) says Mary loads.
    var isConfiguredNode: Bool
    var stats: ThreadNodeStats?
    /// Built here so the pane speaks the builder's line, not the view's.
    var statsLine: String?
}

struct ThreadDiskRow: Identifiable, Equatable {
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

struct ThreadDiskSummary: Equatable {
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

struct ThreadFamilyChip: Identifiable, Equatable {
    var family: ThreadAddressFamily
    var title: String
    var count: Int

    var id: String { family.rawValue }
}

struct ThreadDocumentRow: Identifiable, Equatable {
    var id: String
    var name: String
    var createdAt: Date?
    var family: ThreadAddressFamily
    var familyTitle: String
}

struct ThreadGroupRow: Identifiable, Equatable {
    var id: String
    var label: String
    var documentCount: Int
    var family: ThreadAddressFamily
    var familyTitle: String
    var lane: ThreadLane?
    var isSewnOwned: Bool
    var documents: [ThreadDocumentRow]
}

struct ThreadLaneSection: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var groups: [ThreadGroupRow]
}

/// Drilled document snapshot. Full body or ContributionInspector fallback; degradation named in `notice`.
struct ThreadDocumentDetail: Identifiable, Equatable {
    var id: String
    var name: String
    var groupLabel: String
    var createdAt: Date?
    /// Partition texts in stored order. Nil when only the fallback tier answered.
    var body: String?
    /// Fallback preview from a name-seeded search hit.
    var preview: String?
    var family: ThreadAddressFamily
    var notice: String?
    var codec: BehavioralCodecView? = nil
    var interaction: BehavioralInteractionStub? = nil
}

// MARK: - Graph

/// Request as the panel shapes it — pure, so the clamp is pinnable.
struct ThreadGraphRequestShape: Equatable {
    var query: String
    var kinds: [String]
    var hops: Int
    var limit: Int
    var includeDocuments: Bool
}

// MARK: - Ledger rows

// MARK: - Retrieval rows (built side)

struct ThreadScopeGroupTag: Identifiable, Equatable {
    var id: String
    var label: String
    var family: ThreadAddressFamily
    var familyTitle: String
}

struct ThreadRetrievalRequestRow: Identifiable, Equatable {
    /// Wire `requestID` — which request the contribution answered.
    var id: String
    var transport: SewnTransportKind
    var aggregate: Bool
    var groups: [ThreadScopeGroupTag]
    var relationshipHints: [String]
    var isAnswered: Bool
}

struct ThreadMemoryPlanRow: Equatable {
    var lanes: [String]
    var abilityTargets: [String]
    var expandDisciplineUsage: Bool
    var lanePriority: [String]
    var relationshipHints: [String]
}

/// Builder-computed warning. Derived every build, never stored (live ledgers go stale).
struct ThreadRetrievalWarning: Identifiable, Equatable {
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
struct ThreadRetrievalTurnRow: Identifiable, Equatable {
    var id: String
    var date: Date
    var utterance: String?
    /// intent · decidedBy · rankingMode, from the joined route row.
    var routeLine: String?
    var plan: ThreadMemoryPlanRow?
    var requests: [ThreadRetrievalRequestRow]
    var contribution: SewnContributionTrace?
    var ambient: [AmbientInjectionTrace]
    var promptSpend: [PromptSpendTrace]
    /// Named partial ("no retrieval asked", "no route row…"); nil when complete.
    var state: String?
    var warnings: [ThreadRetrievalWarning]
}
