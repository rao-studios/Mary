//
//  ThreadRetrievalCaptures.swift
//  Mary
//
//  WHAT: App-side fixtures of projection-only Sewn traces.
//  IN:   ThreadExplorerViewModel (sibling split)
//  OUT:  ThreadExplorerViewModel.gather / tests
//  PIN:  Brain traces stay unconstructable; these mirrors are the test seam.
//

import MaryAmbient
import MaryBrain
import MaryFoundation
import MaryThread
import Foundation
import SwiftUI

// MARK: - Retrieval captures (input side)

/// App-side mirror of `SewnRequestTrace`. Brain traces are projection-only;
/// `gather()` projects ledger rows through these; tests construct them directly.
struct ThreadSewnRequestCapture: Equatable {
    var id: String
    var sentAt: Date
    var transport: SewnTransportKind
    var ownerID: String
    var aggregate: Bool
    var groups: [RetrievalScope.Group]
    var relationshipHints: [String]
    var personalThreadID: String?

    init(
        id: String,
        sentAt: Date,
        transport: SewnTransportKind,
        ownerID: String,
        aggregate: Bool,
        groups: [RetrievalScope.Group],
        relationshipHints: [String] = [],
        personalThreadID: String? = nil
    ) {
        self.id = id
        self.sentAt = sentAt
        self.transport = transport
        self.ownerID = ownerID
        self.aggregate = aggregate
        self.groups = groups
        self.relationshipHints = relationshipHints
        self.personalThreadID = personalThreadID
    }

    init(_ trace: SewnRequestTrace) {
        self.init(
            id: trace.id,
            sentAt: trace.sentAt,
            transport: trace.transport,
            ownerID: trace.ownerID,
            aggregate: trace.aggregate,
            groups: trace.groups,
            relationshipHints: trace.relationshipHints,
            personalThreadID: trace.personalThreadID)
    }
}

/// App-side mirror of `RetrievalTraceRecord` — same seam as `ThreadSewnRequestCapture`.
struct ThreadRetrievalCapture: Equatable {
    var id: UUID
    var exchangeID: UUID
    var routeTraceID: UUID?
    var date: Date
    var requests: [ThreadSewnRequestCapture]
    var contribution: SewnContributionTrace?
    var contributionRequestID: String?
    var ambient: [AmbientInjectionTrace]
    var promptSpend: [PromptSpendTrace]

    init(
        id: UUID = UUID(),
        exchangeID: UUID,
        routeTraceID: UUID? = nil,
        date: Date,
        requests: [ThreadSewnRequestCapture] = [],
        contribution: SewnContributionTrace? = nil,
        contributionRequestID: String? = nil,
        ambient: [AmbientInjectionTrace] = [],
        promptSpend: [PromptSpendTrace] = []
    ) {
        self.id = id
        self.exchangeID = exchangeID
        self.routeTraceID = routeTraceID
        self.date = date
        self.requests = requests
        self.contribution = contribution
        self.contributionRequestID = contributionRequestID
        self.ambient = ambient
        self.promptSpend = promptSpend
    }

    init(record: RetrievalTraceRecord) {
        self.init(
            id: record.id,
            exchangeID: record.exchangeID,
            routeTraceID: record.routeTraceID,
            date: record.date,
            requests: record.requests.map(ThreadSewnRequestCapture.init),
            contribution: record.contribution,
            contributionRequestID: record.contributionRequestID,
            ambient: record.ambient,
            promptSpend: record.promptSpend)
    }
}
